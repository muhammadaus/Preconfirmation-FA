// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title IERC721TwoPhase — opt-in two-phase ("2FA") transfer extension for ERC-721.
/// @notice A sender *initiates* a transfer of a `tokenId` bound to a receiver; the
///         token is LOCKED (non-transferable) but ownership stays with the sender
///         until the receiver *accepts*, at which point ownership moves. While pending
///         the sender may revoke; after expiry the sender may reclaim (unlock).
///
/// @dev Design decision — ownership stays with the sender while pending (not moved to
///      the contract). Marketplaces and `ownerOf` / metadata queries keep working; the
///      token is merely locked against transfer. `acceptTransfer` performs the real
///      ownership move. Plain `transferFrom` / `safeTransferFrom` stay atomic and are
///      simply blocked for a pending tokenId.
///
/// @dev ERC-165 interface id: `type(IERC721TwoPhase).interfaceId`.
interface IERC721TwoPhase {
    /*//////////////////////////////////////////////////////////////
                                 TYPES
    //////////////////////////////////////////////////////////////*/

    enum Status {
        None, // 0 — no pending transfer for this id
        Pending, // 1 — token locked, awaiting accept / revoke / reclaim
        Accepted, // 2 — receiver accepted; ownership moved
        Revoked, // 3 — sender revoked while pending
        Reclaimed // 4 — sender reclaimed after expiry
    }

    struct PendingTransfer {
        address from;
        address to;
        uint256 tokenId;
        uint64 expiry; // unix seconds
        Status status;
    }

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event TransferInitiated(
        uint256 indexed id, address indexed from, address indexed to, uint256 tokenId, uint64 expiry
    );

    /// @notice Emitted when the receiver accepts. A standard ERC-721 `Transfer`
    ///         event (from sender to receiver) is emitted alongside this.
    event TransferAccepted(uint256 indexed id);

    event TransferRevoked(uint256 indexed id);

    event TransferReclaimed(uint256 indexed id);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error BadExpiry(); // expiry outside [now+MIN_EXPIRY, now+MAX_EXPIRY]
    error BadReceiver(); // zero receiver, or receiver == sender
    error NotOwner(); // initiate by non-owner (and not approved)
    error NotReceiver(); // accept by non-receiver
    error NotSender(); // revoke / reclaim by non-sender
    error NotPending(); // transfer is not in Pending state
    error NotExpired(); // reclaim before expiry
    error AlreadyPending(); // tokenId already has a pending transfer
    error TokenLocked(); // plain transfer attempted on a pending tokenId

    /*//////////////////////////////////////////////////////////////
                               FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Lock `tokenId` and create a pending transfer bound to `to`.
    /// @dev Caller must be the owner or approved. Ownership is unchanged; the token is
    ///      locked against plain transfers until settled.
    /// @return id Monotonic identifier for this pending transfer.
    function initiateTransfer(address to, uint256 tokenId, uint64 expiry)
        external
        returns (uint256 id);

    /// @notice Bound receiver accepts, moving ownership. Receiver-only.
    function acceptTransfer(uint256 id) external;

    /// @notice Sender revokes a still-pending transfer, unlocking the token. Sender-only.
    function revokeTransfer(uint256 id) external;

    /// @notice Sender reclaims (unlocks) an unaccepted transfer after expiry. Sender-only.
    function reclaimExpired(uint256 id) external;

    /// @notice Read the full record for a pending-transfer id.
    function pendingTransfer(uint256 id) external view returns (PendingTransfer memory);

    /// @notice Whether `tokenId` currently has a pending (locked) transfer.
    function isLocked(uint256 tokenId) external view returns (bool);
}
