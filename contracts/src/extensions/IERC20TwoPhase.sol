// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title IERC20TwoPhase — opt-in two-phase ("2FA") transfer extension for ERC-20.
/// @notice A token implementing this interface lets a sender *initiate* a transfer
///         that does not credit the receiver until the receiver *accepts* it. While
///         pending, the sender may revoke; after expiry the sender may reclaim. This
///         protects against mistaken sends (typos, wrong paste, receiver unaware) —
///         funds never land passively on a wrong address.
///
/// @dev Design decision — plain `transfer()`/`transferFrom()` stay ATOMIC. Two-phase
///      is strictly opt-in per call via `initiateTransfer`, so existing ERC-20
///      invariants and DeFi composability are preserved (see ERC draft Rationale).
///
///      Accounting invariant a conforming token MUST uphold:
///          totalSupply == sum(balanceOf) + sum(pending amounts)
///      The reference implementation satisfies this by escrowing pending amounts in
///      the token contract's own balance, so `sum(balanceOf)` already includes them.
///
/// @dev ERC-165 interface id: `type(IERC20TwoPhase).interfaceId`.
interface IERC20TwoPhase {
    /*//////////////////////////////////////////////////////////////
                                 TYPES
    //////////////////////////////////////////////////////////////*/

    enum Status {
        None, // 0 — slot never used (default for uninitialized reads)
        Pending, // 1 — amount escrowed, awaiting accept / revoke / reclaim
        Accepted, // 2 — receiver accepted; funds credited
        Revoked, // 3 — sender revoked while pending
        Reclaimed // 4 — sender reclaimed after expiry
    }

    struct PendingTransfer {
        address from;
        address to;
        uint256 amount;
        uint64 expiry; // unix seconds
        Status status;
    }

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a sender escrows `amount` into pending state.
    event TransferInitiated(
        uint256 indexed id, address indexed from, address indexed to, uint256 amount, uint64 expiry
    );

    /// @notice Emitted when the bound receiver accepts. A standard ERC-20 `Transfer`
    ///         event (from the escrow to the receiver) is emitted alongside this.
    event TransferAccepted(uint256 indexed id);

    /// @notice Emitted when the sender revokes a still-pending transfer.
    event TransferRevoked(uint256 indexed id);

    /// @notice Emitted when the sender reclaims an expired, unaccepted transfer.
    event TransferReclaimed(uint256 indexed id);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error BadExpiry(); // expiry outside [now+MIN_EXPIRY, now+MAX_EXPIRY]
    error BadAmount(); // zero amount
    error BadReceiver(); // zero receiver, or receiver == sender
    error NotReceiver(); // accept by non-receiver
    error NotSender(); // revoke / reclaim by non-sender
    error NotPending(); // transfer is not in Pending state
    error NotExpired(); // reclaim before expiry

    /*//////////////////////////////////////////////////////////////
                               FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Escrow `amount` from the caller into a pending transfer bound to `to`.
    /// @dev Caller's spendable balance decreases immediately; `to`'s does not increase.
    /// @return id Monotonic identifier for this pending transfer.
    function initiateTransfer(address to, uint256 amount, uint64 expiry)
        external
        returns (uint256 id);

    /// @notice Bound receiver accepts, crediting their balance. Receiver-only.
    function acceptTransfer(uint256 id) external;

    /// @notice Sender revokes a still-pending transfer, refunding themselves. Sender-only.
    function revokeTransfer(uint256 id) external;

    /// @notice Sender reclaims an unaccepted transfer after expiry. Sender-only.
    function reclaimExpired(uint256 id) external;

    /// @notice Read the full record for a pending-transfer id.
    function pendingTransfer(uint256 id) external view returns (PendingTransfer memory);
}
