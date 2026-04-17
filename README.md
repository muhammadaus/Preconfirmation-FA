# Preconfirmation-FA

Safe pending transfers with secret-based confirmation and timeout recovery for Farcaster. Built for FarHack April 2026.

## What it does

Replaces irreversible "push to address" transfers with a **receiver-bound, hash-committed, cancelable escrow** on Base. A transfer requires both receiver key control AND knowledge of a private off-chain secret to claim. Wrong-address mistakes are recoverable — the sender can cancel at any time while pending.

## Architecture

```
Farcaster Mini App (Next.js)  →  Agent API (/api/transfers)  →  Base Sepolia
wagmi + viem                     intent-building only            PendingTransfers.sol
one-secret flow                  never signs txs                 ReentrancyGuard + SafeERC20
```

## Deployed (Base Sepolia)

- **Contract:** [`0xf683F64943BC55726aE9B001A1ae5b731B7804ad`](https://sepolia.basescan.org/address/0xf683F64943BC55726aE9B001A1ae5b731B7804ad)
- **Chain ID:** 84532

## Quick start

### Contracts

```bash
cd contracts
cp ../.env.example ../.env  # fill in PRIVATE_KEY1
forge test -vv              # 21 tests, all pass
forge script script/Deploy.s.sol --rpc-url base_sepolia --broadcast
```

### App

```bash
cd app
cp .env.example .env.local  # set NEXT_PUBLIC_PENDING_TRANSFERS_ADDRESS
pnpm install
pnpm dev
```

## Agent API

| Method | Path | Purpose |
|--------|------|---------|
| `POST` | `/api/transfers` | Build a createETH intent |
| `GET`  | `/api/transfers?user=0x…` | List transfers for a user |
| `GET`  | `/api/transfers/:id` | Read one transfer |
| `POST` | `/api/transfers/:id/claim` | Build a claim intent |
| `POST` | `/api/transfers/:id/cancel` | Build a cancel intent |

## Security model

A transfer is safe when:
1. Funds are held in escrow, not pushed to an address
2. Claim requires `msg.sender == receiver` (key control)
3. Claim requires `keccak256(abi.encode(id, secret)) == commit` (off-chain confirmation)
4. Sender can cancel any time while pending (wrong-address recovery)
5. Receiver must claim before expiry (10 min – 7 days)
