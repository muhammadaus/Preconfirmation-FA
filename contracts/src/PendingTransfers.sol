// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title PendingTransfers — receiver-bound, hash-committed, cancelable escrow.
/// @notice Replaces "push to pasted address" with a pending transfer that
///         requires BOTH receiver key control AND knowledge of an off-chain
///         secret to settle. Sender may cancel any time while pending; receivers
///         may claim only before expiry.
///
/// Security properties:
///   - msg.sender == receiver   (key control, same as a normal transfer)
///   - keccak256 commit         (out-of-band confirmation, not inferable on-chain)
///   - expiry                   (receiver deadline; after which only sender can cancel)
///   - ReentrancyGuard          (defends against malicious ERC-20 reentry on payout)
///   - Checks-effects-interactions ordering on every state transition.
contract PendingTransfers is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                 TYPES
    //////////////////////////////////////////////////////////////*/

    enum Status {
        None,      // 0 — slot never used (default for uninitialized mapping reads)
        Pending,   // 1 — funds locked, awaiting claim or cancel
        Claimed,   // 2 — receiver successfully revealed the secret
        Cancelled  // 3 — sender reclaimed the funds
    }

    struct Pending {
        address sender;
        address receiver;
        address token;     // address(0) == native ETH
        uint256 amount;
        bytes32 commit;    // see _computeCommit() for preimage layout
        uint64  expiry;    // unix seconds; 0 is invalid
        Status  status;
    }

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @dev Deterministic id → transfer. Ids are collision-resistant by construction
    ///      (see _computeId). Using bytes32 keys keeps one slot per transfer.
    mapping(bytes32 id => Pending) public transfers;

    /// @dev Per-sender nonce feeding into the id derivation. Monotonic, never reused.
    mapping(address sender => uint256) public nonces;

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Minimum expiry window the receiver is guaranteed, relative to now.
    /// @dev Chosen so that a genuine P2P hand-off (read code aloud, type it in) is
    ///      achievable without a race, but short enough that a mis-clicked transfer
    ///      doesn't lock funds for long. Note: sender can still cancel anytime while
    ///      pending, so this is really a "receiver gets at least N minutes" guarantee.
    uint64 public constant MIN_EXPIRY = 10 minutes;

    /// @notice Maximum expiry window, relative to now. Prevents accidental decade-long
    ///         lockups from typos in the expiry field.
    uint64 public constant MAX_EXPIRY = 7 days;

    /// @notice Sentinel for native ETH. The zero address can never be a real ERC-20
    ///         (would fail `code.length > 0` checks inside SafeERC20 anyway).
    address public constant NATIVE = address(0);

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event TransferCreated(
        bytes32 indexed id,
        address indexed sender,
        address indexed receiver,
        address token,
        uint256 amount,
        bytes32 commit,
        uint64  expiry
    );

    event TransferClaimed(
        bytes32 indexed id,
        address indexed sender,
        address indexed receiver,
        address token,
        uint256 amount
    );

    event TransferCancelled(
        bytes32 indexed id,
        address indexed sender,
        address indexed receiver,
        address token,
        uint256 amount
    );

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error BadExpiry();        // expiry outside [now+MIN_EXPIRY, now+MAX_EXPIRY]
    error BadAmount();        // zero amount, or msg.value mismatch for native
    error NotReceiver();      // claim by non-receiver
    error NotSender();        // cancel by non-sender
    error BadSecret();        // secret preimage doesn't match commit
    error Expired();          // claim after expiry
    error AlreadySettled();   // transfer is not in Pending state (claimed or cancelled)
    error BadCommit();        // commit == 0x0 (almost certainly a client bug)

    /*//////////////////////////////////////////////////////////////
                                 CREATE
    //////////////////////////////////////////////////////////////*/

    /// @notice Create a pending transfer of native ETH.
    /// @param receiver  The address that will be allowed to claim.
    /// @param commit    keccak256 of the preimage defined by _computeCommit.
    /// @param expiry    Absolute unix seconds by which receiver must claim.
    /// @return id       Deterministic identifier for this transfer.
    function createETH(address receiver, bytes32 commit, uint64 expiry)
        external
        payable
        returns (bytes32 id)
    {
        _validateCreate(receiver, msg.value, commit, expiry);
        id = _computeId(msg.sender, receiver, NATIVE, msg.value);

        transfers[id] = Pending({
            sender:   msg.sender,
            receiver: receiver,
            token:    NATIVE,
            amount:   msg.value,
            commit:   commit,
            expiry:   expiry,
            status:   Status.Pending
        });

        emit TransferCreated(id, msg.sender, receiver, NATIVE, msg.value, commit, expiry);
    }

    /// @notice Create a pending transfer of an ERC-20 token. Sender must have
    ///         approved this contract for `amount` beforehand.
    function createERC20(
        address receiver,
        address token,
        uint256 amount,
        bytes32 commit,
        uint64  expiry
    ) external returns (bytes32 id) {
        if (token == NATIVE) revert BadAmount(); // use createETH
        _validateCreate(receiver, amount, commit, expiry);

        id = _computeId(msg.sender, receiver, token, amount);

        transfers[id] = Pending({
            sender:   msg.sender,
            receiver: receiver,
            token:    token,
            amount:   amount,
            commit:   commit,
            expiry:   expiry,
            status:   Status.Pending
        });

        // Pull funds AFTER writing state — classic CEI. SafeERC20 reverts on failure.
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        emit TransferCreated(id, msg.sender, receiver, token, amount, commit, expiry);
    }

    /*//////////////////////////////////////////////////////////////
                                  CLAIM
    //////////////////////////////////////////////////////////////*/

    /// @notice Receiver reveals the secret and takes the funds.
    /// @dev Reverts with a specific named error for each failure mode so the
    ///      UI can render a meaningful message without parsing strings.
    function claim(bytes32 id, bytes32 secret) external nonReentrant {
        Pending storage t = transfers[id];

        if (t.status != Status.Pending)         revert AlreadySettled();
        if (msg.sender != t.receiver)           revert NotReceiver();
        if (block.timestamp > t.expiry)         revert Expired();
        if (_computeCommit(id, secret) != t.commit) revert BadSecret();

        // Effects BEFORE interactions.
        t.status = Status.Claimed;

        address token  = t.token;
        uint256 amount = t.amount;
        address to     = t.receiver;

        if (token == NATIVE) {
            (bool ok,) = to.call{value: amount}("");
            require(ok, "native transfer failed");
        } else {
            IERC20(token).safeTransfer(to, amount);
        }

        emit TransferClaimed(id, t.sender, to, token, amount);
    }

    /*//////////////////////////////////////////////////////////////
                                 CANCEL
    //////////////////////////////////////////////////////////////*/

    /// @notice Sender reclaims funds. Permitted any time while the transfer is
    ///         Pending — design decision: optimizing for the "wrong recipient,
    ///         let me fix it" recovery case is more important than guaranteeing
    ///         the receiver an irrevocable window. Expired transfers are also
    ///         cancelable (by design — this is the sole recovery path for
    ///         unclaimed funds).
    function cancel(bytes32 id) external nonReentrant {
        Pending storage t = transfers[id];

        if (t.status != Status.Pending) revert AlreadySettled();
        if (msg.sender != t.sender)     revert NotSender();

        t.status = Status.Cancelled;

        address token  = t.token;
        uint256 amount = t.amount;
        address to     = t.sender;
        address receiver = t.receiver;

        if (token == NATIVE) {
            (bool ok,) = to.call{value: amount}("");
            require(ok, "native refund failed");
        } else {
            IERC20(token).safeTransfer(to, amount);
        }

        emit TransferCancelled(id, to, receiver, token, amount);
    }

    /*//////////////////////////////////////////////////////////////
                                  VIEWS
    //////////////////////////////////////////////////////////////*/

    function getTransfer(bytes32 id) external view returns (Pending memory) {
        return transfers[id];
    }

    /// @notice Preview the id a `create*` call will produce for given params.
    /// @dev Useful for the client to compute commit = _computeCommit(previewId, secret)
    ///      BEFORE sending the create tx. Reads the sender's current nonce, so the
    ///      preview is only stable if no other create from the same sender lands first.
    function previewId(address sender, address receiver, address token, uint256 amount)
        external
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encode(sender, receiver, token, amount, nonces[sender], block.chainid)
        );
    }

    /*//////////////////////////////////////////////////////////////
                               INTERNALS
    //////////////////////////////////////////////////////////////*/

    function _validateCreate(
        address receiver,
        uint256 amount,
        bytes32 commit,
        uint64  expiry
    ) private view {
        if (amount == 0)                    revert BadAmount();
        if (receiver == address(0))         revert BadAmount(); // reuse error; 0 receiver is nonsense
        if (commit == bytes32(0))           revert BadCommit();
        if (expiry < block.timestamp + MIN_EXPIRY) revert BadExpiry();
        if (expiry > block.timestamp + MAX_EXPIRY) revert BadExpiry();
    }

    /// @dev Consumes & increments the per-sender nonce. Because the nonce is part
    ///      of the preimage, even identical (sender, receiver, token, amount) tuples
    ///      produce distinct ids across successive creates.
    function _computeId(address sender, address receiver, address token, uint256 amount)
        private
        returns (bytes32 id)
    {
        uint256 n = nonces[sender]++;
        id = keccak256(abi.encode(sender, receiver, token, amount, n, block.chainid));
    }

    /// @notice Commitment preimage layout: keccak256(abi.encode(id, secret)).
    /// @dev `abi.encode` is chosen over `abi.encodePacked` as a forward-compatibility
    ///      policy — for the current (bytes32, bytes32) shape the bytes are identical,
    ///      but `encode` stays collision-safe if the preimage ever grows a dynamic
    ///      field (EIP-712 uses the same rationale). The client-side helper in
    ///      app/lib/secret.ts MUST mirror this exact formula via viem's
    ///      `encodeAbiParameters([{type:'bytes32'},{type:'bytes32'}], [id, secret])`.
    function _computeCommit(bytes32 id, bytes32 secret) private pure returns (bytes32) {
        return keccak256(abi.encode(id, secret));
    }

    /*//////////////////////////////////////////////////////////////
                               RECEIVE
    //////////////////////////////////////////////////////////////*/

    /// @dev Reject stray ETH sent without a create call — prevents stuck funds
    ///      that no createETH claims owns. Forces senders through the intended API.
    receive() external payable {
        revert("use createETH");
    }
}
