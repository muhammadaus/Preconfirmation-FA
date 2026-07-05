# ERC-XXXX: Two-Phase Token Transfers

> **Status:** Draft  
> **Category:** ERC  
> **Requires:** ERC-20, ERC-721, ERC-165  
> **Created:** 2026-07-04  
> **Authors:** Preconfirmation-FA contributors  

---

## Abstract

This document specifies an **opt-in extension** to ERC-20 and ERC-721 that replaces atomic
push-to-address settlement with a two-step lifecycle: *initiate* (sender locks funds) →
*accept* (receiver confirms) → settle. Unaccepted transfers are reclaimable by the sender
at any time while pending; they expire automatically if not accepted within a bounded window.
Plain `transfer()` / `transferFrom()` semantics are **preserved unchanged** so that existing
DeFi integrations are not broken.

The extension introduces two interfaces, `IERC20TwoPhase` and `IERC721TwoPhase`, both
discoverable via ERC-165, enabling wallets and dapps to surface pending-inbound UX uniformly
across compliant tokens.

---

## Motivation

EVM token transfers are irrevocable by design. Once `transfer(to, amount)` executes, the
recipient owns the funds; the sender has no recourse. In practice this creates a well-documented
loss class: addresses mistyped by one character, clipboard poisoning, QR-code substitution, or
simply sending to a contact who is no longer reachable at that address. Blockchain analytics
firms (Chainalysis, Elliptic) have reported hundreds of millions of dollars permanently locked
in unreachable addresses annually.

Several mitigations exist but none address the root cause at the token layer:

- **Smart wallets / address books** — useful, but they operate off-chain and protect only users
  who have opted in to the specific wallet software.
- **External escrow (e.g., this repo's `PendingTransfers.sol`)** — retrofits two-phase behavior
  onto already-deployed tokens but adds friction (separate contract approval, two-step
  interaction for every transfer).
- **Multi-sig and social recovery** — solve key loss, not wrong-address loss.

A token-native two-phase interface solves the problem once, in the token itself, and lets
wallets discover and render the pending-inbound state without any external contract.

### Receiver-acknowledgment asymmetry

Plain ERC-20 has a fundamental asymmetry: the sender acts, the receiver is passive. If the
receiver's address is wrong, the wrong party owns the funds with zero further action required.
Two-phase transfers invert this: funds enter a pending state bound to `to`, and the receiver
must actively sign an `acceptTransfer` transaction before settlement occurs. Until then, the
sender can revoke. The wrong party at a mistyped address must actively accept — they cannot
receive funds passively.

---

## Specification

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT", "SHOULD", "SHOULD NOT",
"RECOMMENDED", "MAY", and "OPTIONAL" in this document are to be interpreted as described in
RFC 2119.

### Definitions

- **Pending transfer** — a transfer that has been initiated but not yet accepted or revoked.
- **Expiry** — an absolute Unix timestamp after which the receiver can no longer accept;
  the sender MAY reclaim at or after expiry via `reclaimExpired`.
- **Transfer ID** — a `uint256` uniquely identifying a pending transfer within a given token
  contract.

### IERC20TwoPhase

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @title IERC20TwoPhase
/// @notice Optional ERC-20 extension: two-phase (initiate → accept) transfers with
///         sender-revocable pending state and bounded expiry.
interface IERC20TwoPhase is IERC165 {

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /// @notice Emitted when a transfer is initiated and funds enter pending state.
    /// @param transferId Unique id for this pending transfer within this token.
    /// @param from       Initiating sender; funds debited from this balance.
    /// @param to         Intended receiver; the only address that may accept.
    /// @param amount     Token units locked in pending state.
    /// @param expiry     Absolute Unix timestamp after which receiver cannot accept.
    event TransferInitiated(
        uint256 indexed transferId,
        address indexed from,
        address indexed to,
        uint256 amount,
        uint64  expiry
    );

    /// @notice Emitted when the receiver accepts a pending transfer and funds are credited.
    /// @param transferId The id that was accepted.
    event TransferAccepted(uint256 indexed transferId);

    /// @notice Emitted when the sender revokes a pending transfer and funds are returned.
    /// @param transferId The id that was revoked.
    event TransferRevoked(uint256 indexed transferId);

    // -------------------------------------------------------------------------
    // State-changing functions
    // -------------------------------------------------------------------------

    /// @notice Initiate a two-phase transfer. `amount` MUST be deducted from the
    ///         caller's spendable balance immediately and held in pending state.
    ///         The receiver's balance MUST NOT increase until `acceptTransfer` succeeds.
    ///
    /// @dev Callers MUST supply an expiry in [block.timestamp + MIN_EXPIRY,
    ///      block.timestamp + MAX_EXPIRY]; the implementation MUST revert otherwise.
    ///      Implementations SHOULD use a collision-resistant id derivation that includes
    ///      at least (msg.sender, to, amount, per-sender-nonce, block.chainid) so that
    ///      replays across chains and successive calls with identical parameters produce
    ///      distinct ids.
    ///
    /// @param to      Intended receiver. MUST NOT be the zero address.
    /// @param amount  Token units to lock. MUST be greater than zero.
    /// @param expiry  Absolute Unix timestamp; receiver deadline.
    /// @return transferId Unique identifier for the initiated pending transfer.
    function initiateTransfer(address to, uint256 amount, uint64 expiry)
        external
        returns (uint256 transferId);

    /// @notice Accept a pending transfer. MUST be called by the pending receiver
    ///         (`msg.sender == pending.to`). MUST revert if the transfer has expired,
    ///         has already been accepted, or has been revoked. On success, the amount
    ///         MUST be credited to the receiver and a standard ERC-20 `Transfer` event
    ///         MUST be emitted.
    ///
    /// @param transferId The id returned by `initiateTransfer`.
    function acceptTransfer(uint256 transferId) external;

    /// @notice Revoke a pending transfer, returning funds to the sender. MUST be called
    ///         by the original sender (`msg.sender == pending.from`). MUST revert if the
    ///         transfer has already been accepted or revoked. MAY be called at any time
    ///         while the transfer is pending, including after expiry.
    ///
    /// @param transferId The id returned by `initiateTransfer`.
    function revokeTransfer(uint256 transferId) external;

    /// @notice Reclaim an expired pending transfer, returning funds to the sender.
    ///         MUST revert if the transfer has not yet expired, or if the transfer is
    ///         not in the pending state. Implementations SHOULD restrict this to the
    ///         original sender only (mirroring the "cancel is the sole recovery path"
    ///         design of external escrow contracts) rather than allowing any caller,
    ///         to prevent griefing by third parties settling transfers on behalf of
    ///         senders who may still be deciding.
    ///
    /// @param transferId The id returned by `initiateTransfer`.
    function reclaimExpired(uint256 transferId) external;

    // -------------------------------------------------------------------------
    // View functions
    // -------------------------------------------------------------------------

    /// @notice Minimum expiry duration an implementation MUST enforce, in seconds
    ///         relative to `block.timestamp` at initiation time. Implementations
    ///         SHOULD set this to at least 600 (10 minutes) so that a genuine
    ///         peer-to-peer hand-off is achievable without a race against the clock.
    function MIN_EXPIRY() external view returns (uint64);

    /// @notice Maximum expiry duration an implementation MUST enforce, in seconds
    ///         relative to `block.timestamp` at initiation time. Implementations
    ///         SHOULD set this to at most 604800 (7 days) to prevent accidental
    ///         long-duration lockups from typos in the expiry field.
    function MAX_EXPIRY() external view returns (uint64);

    /// @notice ERC-165 interface id for this extension.
    ///         keccak256("IERC20TwoPhase") truncated to 4 bytes (to be computed at
    ///         finalization time once all selectors are fixed).
    // bytes4 public constant IERC20TWOPHASE_ID = 0xXXXXXXXX;
}
```

### IERC721TwoPhase

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @title IERC721TwoPhase
/// @notice Optional ERC-721 extension: two-phase ownership transfer with
///         sender-revocable pending state and bounded expiry.
///
/// @dev Ownership-lock model: while a tokenId is pending, the token contract
///      MUST prevent any transfer of that token (sale, safeTransferFrom, approve-
///      then-transfer, etc.). Recorded ownership SHOULD remain with the sender
///      during the pending window so that marketplace metadata / ownership queries
///      continue to resolve correctly. `acceptTransfer` performs the actual
///      ownership move, at which point a standard ERC-721 `Transfer` event is emitted.
interface IERC721TwoPhase is IERC165 {

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /// @notice Emitted when a token is locked into a pending two-phase transfer.
    /// @param transferId Unique id for this pending transfer within this token contract.
    /// @param from       Current owner / sender; token locked but ownership unchanged.
    /// @param to         Intended receiver; only address that may accept.
    /// @param tokenId    The locked token.
    /// @param expiry     Absolute Unix timestamp after which receiver cannot accept.
    event TransferInitiated(
        uint256 indexed transferId,
        address indexed from,
        address indexed to,
        uint256 tokenId,
        uint64  expiry
    );

    /// @notice Emitted when the receiver accepts; ownership of `tokenId` moves to `to`.
    /// @param transferId The id that was accepted.
    event TransferAccepted(uint256 indexed transferId);

    /// @notice Emitted when the sender revokes; lock is released, ownership unchanged.
    /// @param transferId The id that was revoked.
    event TransferRevoked(uint256 indexed transferId);

    // -------------------------------------------------------------------------
    // State-changing functions
    // -------------------------------------------------------------------------

    /// @notice Initiate a two-phase ownership transfer. The token MUST be locked
    ///         immediately (no further transfers or approvals of this tokenId until
    ///         the pending transfer is resolved). Ownership record MUST remain with
    ///         the sender during the pending window. A given tokenId MUST NOT have
    ///         more than one simultaneous pending transfer; implementations MUST
    ///         revert if the tokenId is already pending.
    ///
    /// @param to       Intended receiver. MUST NOT be the zero address.
    /// @param tokenId  The token to transfer. Caller MUST be the owner or approved.
    /// @param expiry   Absolute Unix timestamp; receiver deadline.
    /// @return transferId Unique identifier for the initiated pending transfer.
    function initiateTransfer(address to, uint256 tokenId, uint64 expiry)
        external
        returns (uint256 transferId);

    /// @notice Accept a pending transfer. MUST be called by the pending receiver.
    ///         MUST revert if expired, already accepted, or already revoked. On
    ///         success, ownership of the tokenId MUST move to the receiver and a
    ///         standard ERC-721 `Transfer` event MUST be emitted.
    ///
    /// @param transferId The id returned by `initiateTransfer`.
    function acceptTransfer(uint256 transferId) external;

    /// @notice Revoke a pending transfer. MUST be called by the original sender.
    ///         Lock MUST be released; ownership remains with the sender. MUST revert
    ///         if the transfer is not pending.
    ///
    /// @param transferId The id returned by `initiateTransfer`.
    function revokeTransfer(uint256 transferId) external;

    /// @notice Reclaim an expired pending transfer. Lock is released; ownership
    ///         remains with the sender. MUST revert if the transfer has not expired
    ///         or is not pending. SHOULD be restricted to the original sender only.
    ///
    /// @param transferId The id returned by `initiateTransfer`.
    function reclaimExpired(uint256 transferId) external;

    // -------------------------------------------------------------------------
    // View functions
    // -------------------------------------------------------------------------

    /// @notice Returns true if `tokenId` is currently locked in a pending transfer.
    function isPending(uint256 tokenId) external view returns (bool);

    function MIN_EXPIRY() external view returns (uint64);
    function MAX_EXPIRY() external view returns (uint64);
}
```

### Compatibility with base ERC-20 / ERC-721

Implementations MUST preserve existing `transfer`, `transferFrom`, `safeTransferFrom` semantics.
Plain transfers MUST remain atomic. The two-phase lifecycle is initiated only by explicit calls
to `initiateTransfer`. This is the **opt-in per call** model; the alternative — routing every
plain transfer through two-phase — would break every existing DeFi and marketplace integration
and is explicitly NOT specified here (see Rationale).

### ERC-165 detection

Compliant implementations MUST return `true` for `supportsInterface(IERC20TWOPHASE_ID)` or
`supportsInterface(IERC721TWOPHASE_ID)`. Wallets and dapps MUST use this check to decide
whether to render the pending-inbound UI, rather than relying on bytecode inspection or
off-chain registries.

---

## Rationale

### Is this worth an ERC? — Honest analysis

#### Arguments in favor

1. **Quantifiable loss class.** Misdirected ERC-20 transfers are not theoretical. Billions of
   dollars sit permanently in unreachable addresses. The loss is irreversible by design and
   the frequency scales with the user base.
2. **Receiver-acknowledgment closes a real gap.** Plain ERC-20 is sender-unilateral: the
   receiver has no channel through which to refuse or acknowledge. Two-phase gives both parties
   agency over settlement.
3. **Uniform wallet UX.** Without a standard interface, every wallet that wants to surface
   pending-inbound transfers must either integrate a specific escrow contract or invent its own
   schema. A standard lets wallets query `supportsInterface` and render a canonical "you have a
   pending incoming transfer — accept or wait for it to expire" experience.

#### Arguments against

1. **Breaks the atomic-settlement assumption DeFi relies on.** AMMs, lending protocols, yield
   aggregators — all assume that a `transfer` call either succeeds and moves funds, or reverts.
   A token that can hold funds in pending limbo cannot serve as a pool asset in pending mode
   without significant protocol redesign. The opt-in model specified here mitigates this
   substantially (plain `transfer` remains atomic), but a two-phase-native token is still not
   drop-in equivalent to a plain ERC-20 in every integration context.
2. **Doubles gas and UX steps for the 99% of correct transfers.** For the common case —
   sending to the right address — two-phase adds latency and a second transaction. This is a
   meaningful regression for high-frequency use cases (payroll, payments, L2 bridges).
3. **Application-layer alternatives are mature.** Smart wallet address books, ENS, named
   transfer protocols, and external escrow contracts (see this repo's `PendingTransfers.sol`)
   solve most of the misdirected-send problem without touching the token layer.
4. **Prior art reached limited adoption.** Several related standards have been proposed and
   none has seen meaningful deployment:
   - **ERC-1996 (Holdable Token)** — defines a hold lifecycle with notary, expiry, and lockup,
     targeting payment use cases; never formally finalized.
   - **ERC-2020 (E-Money Standard Token)** — comprehensive payment token with holds, freezes,
     and compliance hooks; complex and narrowly scoped to regulated e-money.
   - **ERC-5528 (Refundable Token)** — buyer-refundable fungible tokens using escrow-like
     accounting; different use case but similar two-phase intuition.
   - **External escrow (this repo's `PendingTransfers`)** — the pragmatic, deployable alternative:
     works with any already-deployed ERC-20 or native ETH, requires no token modification, and
     provides an additional out-of-band secret factor for stronger protection. It is the only
     retrofit path for tokens already in production.

#### Honest conclusion

This extension is strongest as two things simultaneously:

1. **An opt-in extension for newly deployed tokens** where the issuer wants receiver-
   acknowledgment semantics built into the token itself (e.g., payment stablecoins, corporate
   treasury tokens, or any token primarily used for P2P value transfer rather than DeFi liquidity).
2. **A wallet UX standard** — a common interface lets wallets detect two-phase-capable tokens
   and render consistent pending-inbound UI without per-token integration work.

For **existing tokens already deployed** at a fixed address, external escrow (exemplified by
`contracts/src/PendingTransfers.sol` in this repo) remains the only viable retrofit path.
`PendingTransfers` also provides a stronger security model — requiring both receiver key control
*and* an off-chain secret — which is orthogonal to the simpler acceptance-acknowledgment model
described in this ERC.

This extension is **not** a replacement for base ERC-20 semantics. Mandating two-phase for all
transfers would break the ecosystem; the opt-in model specified here is the appropriate scope.

### Plain-transfer compatibility decision

Two options were considered for plain `transfer()`:

- **(a) Stays atomic — opt-in per call (RECOMMENDED and SPECIFIED HERE).** The extension
  adds new functions; existing functions are unchanged. DeFi composability is preserved.
  Token issuers choose whether to expose two-phase for specific use cases.
- **(b) Route all transfers through two-phase.** Breaks every AMM, lending protocol, and
  bridge that calls `transfer`. This option is explicitly rejected.

### ERC-721 lock model

Two ownership models during a pending ERC-721 transfer were considered:

- **Transfer custody to the contract.** `ownerOf(tokenId)` returns the contract address while
  pending. Breaks marketplace metadata queries (rarity tools, OpenSea, etc.) that assume the
  owner is a human-controlled address.
- **Keep ownership with sender, set a lock (RECOMMENDED and SPECIFIED HERE).** `ownerOf`
  continues to return the sender; any call to `transferFrom`, `safeTransferFrom`, or `approve`
  on the locked token MUST revert. `acceptTransfer` performs the actual ownership move.
  Implementations SHOULD override `_update` (OZ ERC721 v5) or the equivalent internal hook to
  enforce the lock.

The lock model is preferred because it preserves existing marketplace and explorer UX for
tokens that have not yet been accepted.

### Expiry bounds (MIN_EXPIRY / MAX_EXPIRY)

Expiry is bounded rather than left open-ended for two reasons:

- **Lower bound (RECOMMENDED: 600 seconds / 10 minutes).** A genuine peer-to-peer hand-off
  — communicating the transfer out-of-band, reading the receiver code, typing an acceptance
  transaction — must be achievable without a time-pressure race. 10 minutes provides a
  comfortable window. The sender retains the ability to revoke at any time during this window,
  so the lower bound does not materially reduce sender flexibility; it is purely a receiver
  guarantee.
- **Upper bound (RECOMMENDED: 604800 seconds / 7 days).** Prevents accidental decade-long
  lockups caused by a typo in the expiry field (e.g., passing a timestamp in milliseconds
  rather than seconds). 7 days is long enough for any reasonable acknowledgment workflow
  including slow cross-timezone communication.

These values are drawn from the reference implementation (`PendingTransfers.sol:63-67`) where
they have been validated in production on Base.

---

## Backwards Compatibility

This ERC introduces new functions and events on top of ERC-20 and ERC-721. It does not modify
any existing function signatures, return types, or event semantics. Existing contracts,
aggregators, DEXs, and marketplaces that call only the base ERC-20 or ERC-721 interface are
unaffected.

Tokens that implement this extension SHOULD announce it via ERC-165 so that integrators can
detect two-phase capability without any source-code inspection.

---

## Security Considerations

### Why this works — no loophole for an accidental third party to take the funds

The design provides genuine two-factor protection. Each factor independently excludes an
accidental third-party recipient:

**Factor 1 — receiver's private key.** Funds never sit at a bare address after initiation; they
are held in the token's internal pending state, bound to `to`. Settlement requires
`msg.sender == pending.to`, meaning a signed transaction from that exact key. A stranger at a
mistyped address can only receive if they *actively sign an acceptTransfer transaction* — funds
cannot land on them passively. Until someone accepts, the sender can revoke. This is a
structural improvement over plain ERC-20, where the mistyped address owns funds *instantly*
with no further action required.

**Factor 2 — the acceptance window as a confirmation channel.** Even if the wrong address
belongs to an active wallet that notices the pending transfer and tries to accept it, the sender
can revoke before any accept is mined, especially since the pending state is visible on-chain
and wallets implementing this standard will surface it to the sender. For implementations that
add an additional out-of-band secret (as in `PendingTransfers.sol`), the receiver must *also*
hold the secret, providing a second independent exclusion.

**Why there is no bypass path:**

- The contract holds custody while pending, so no other function can move the funds.
- Transfer IDs are collision-resistant (implementors SHOULD include sender nonce and `chainid`
  in the derivation preimage, so there are no replays across chains or successive identical
  calls).
- CEI (Checks-Effects-Interactions) ordering and `ReentrancyGuard` rule out drain-via-reentry.
- After expiry, the only recovery path is `reclaimExpired` back to the sender.

### Explicit out-of-scope: social engineering

This extension protects against *mistaken* sends (typos, wrong paste, clipboard poisoning,
receiver unaware of funds). It does **not** protect against social engineering — a scenario
where the victim is deliberately deceived into naming a malicious address as receiver, AND
subsequently signs the `acceptTransfer` transaction because they were convinced to do so. In
that case, both factors are willingly provided by the victim to the attacker. This threat model
is explicitly out of scope; wallets and dapps SHOULD include appropriate warnings, but the
token contract cannot prevent a user who has been socially engineered.

### Griefing via dust pending-spam

An attacker can initiate many small pending transfers to a victim address, potentially creating
UI noise or consuming storage gas for the receiver. Mitigations:

- Implementations SHOULD charge at least enough gas to make large-scale spam economically
  unattractive.
- Wallets rendering pending-inbound UI SHOULD allow users to ignore or hide transfers below a
  threshold amount.
- The bounded expiry guarantees that spam transfers self-expire within `MAX_EXPIRY`.

### Accounting invariant

Implementations MUST maintain the following invariant at all times:

```
totalSupply() == sum(all balances) + sum(all pending transfer amounts)
```

Funds in pending state MUST be excluded from the sender's `balanceOf` return value and MUST NOT
be included in the receiver's `balanceOf` until `acceptTransfer` succeeds. Violating this
invariant would allow a sender to double-spend by initiating a transfer and then using the same
funds in a plain transfer or DeFi interaction.

### Front-running

An attacker who observes an `acceptTransfer` transaction in the mempool cannot front-run it to
steal the funds: they are not the bound receiver, so the contract will reject their `accept`
call. For implementations with an additional out-of-band secret (see `PendingTransfers.sol`),
knowing the secret from the mempool is also insufficient because they must *also* be the bound
receiver — knowledge of one factor alone provides no benefit.

### Expiry and block-timestamp manipulation

Implementations rely on `block.timestamp` for expiry enforcement. Miners / validators can
manipulate timestamps within a bounded range (typically ~15 seconds on Ethereum mainnet).
Given that `MIN_EXPIRY` is recommended at 10 minutes, short-range timestamp manipulation
cannot be exploited to deny a legitimate accept call.

---

## Reference Implementation

Reference Solidity implementations are located at:

- `contracts/src/extensions/IERC20TwoPhase.sol` — interface with full NatSpec
- `contracts/src/extensions/ERC20TwoPhase.sol` — abstract extension over OpenZeppelin `ERC20`
- `contracts/src/extensions/IERC721TwoPhase.sol` — interface with full NatSpec
- `contracts/src/extensions/ERC721TwoPhase.sol` — abstract extension over OpenZeppelin `ERC721`,
  using `_update` override to enforce the token lock
- `contracts/src/mocks/TwoPhaseToken.sol` — concrete mintable ERC-20 mock for tests
- `contracts/src/mocks/TwoPhaseNFT.sol` — concrete mintable ERC-721 mock for tests

Tests are in `contracts/test/ERC20TwoPhase.t.sol` and `contracts/test/ERC721TwoPhase.t.sol`.

The external escrow reference implementation — which adds a second factor (off-chain secret)
and works with any already-deployed ERC-20 — is at `contracts/src/PendingTransfers.sol`.

---

## Copyright

Copyright and related rights waived via [CC0](https://creativecommons.org/publicdomain/zero/1.0/).
