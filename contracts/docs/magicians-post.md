# Ethereum Magicians post draft

Post this at https://ethereum-magicians.org, category **ERCs**, suggested tags: `erc`, `token`, `wallet`.
After posting, put the thread URL into the `discussions-to` field of the draft, and after opening
the ethereum/ERCs PR, replace both `TBD`s with the PR number.

---

**Title:** ERC-TBD: Two-Phase Asset Transfers

**Body:**

Hi all,

I am proposing a standard for two-phase transfers: the sender initiates, the asset is locked and
bound to a named receiver, and nothing settles until that receiver accepts. Until someone
accepts, the sender can revoke at any time. After a deadline, the sender can reclaim.

Draft: (link to the ethereum/ERCs PR once opened)

## The problem

A normal transfer is one-sided. The sender acts, the receiver does nothing, and a mistyped or
poisoned address owns the funds the moment the transaction lands. Address books and smart
wallets help the people who use them, but the root cause is that the receiver never has a say.

## What the standard specifies

- A single lifecycle: `initiateTransfer` -> `acceptTransfer` (receiver only) -> settle, plus
  `revokeTransfer` (sender, any time while pending) and `reclaimExpired` (sender, after expiry).
- Two conforming embodiments:
  1. A standalone escrow (`ITwoPhaseEscrow`) that retrofits the lifecycle onto native ETH and
     any already-deployed ERC-20, ERC-721, or ERC-1155. One contract, one wallet integration,
     every asset class.
  2. Token-native extensions (`IERC20TwoPhase`, `IERC721TwoPhase`) for new tokens, discoverable
     via ERC-165. Plain `transfer` / `transferFrom` semantics are untouched, so existing DeFi
     and marketplace integrations keep working.
- An optional second factor (committed mode). The sender generates a throwaway secp256k1 key
  and hands it to the receiver off-chain, only after the receiver confirms the address is
  really theirs. Accepting then requires the receiver's own key AND a signature made with the
  secret key. This stops the one case receiver-acceptance alone does not: an active stranger at
  a wrong address who sees the pending transfer and accepts it.

## The design decision I most want feedback on

The obvious committed-mode design (store a hash, receiver submits the raw preimage) is broken
in the mempool: the reveal code sits in calldata and is public to every mempool watcher the
moment the accept is broadcast, even if the transaction reverts. A receiver who submits from
the wrong account by mistake burns the secret publicly and gets nothing.

So the draft instead proves the secret by signature. The secret is a private key; the receiver
signs `keccak256(abi.encode(chainid, contract, transferId, msg.sender))` with it. The raw key
never appears on-chain, mined or reverted. An observed signature cannot be replayed (it names
the caller's account) and cannot be inverted into the key. Cost is one ecrecover.

## Prior art

ERC-1996 (Holdable Token), ERC-2020, and ERC-5528 touched adjacent ground and stalled. This
draft differs by covering native ETH and already-deployed tokens through the escrow embodiment,
by keeping base transfer semantics untouched, and by specifying the mempool-safe second factor.

## Questions for the group

1. Is the two-embodiment structure (escrow + token-native) acceptable in one ERC, or should it
   be split?
2. Committed mode is optional per transfer. Should it be a separate extension interface
   instead?
3. Are the RECOMMENDED expiry bounds (10 minutes to 7 days) reasonable defaults?
4. Any holes in the signature-based accept proof I have missed?

Reference implementations (Foundry, full test suite) will be in the PR's assets directory.
Feedback welcome.
