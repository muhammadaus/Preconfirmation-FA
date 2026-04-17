# Preconfirmation-FA — Agent / CLI Integration

Use these examples to interact with the Preconfirmation escrow system from LLM agents, scripts, or any HTTP client.

## Setup

```bash
# Deployed API (update after Vercel deploy)
export BASE_URL="https://app-fawn-ten-85.vercel.app"

# Contract on Base Sepolia
export CONTRACT="0xf683F64943BC55726aE9B001A1ae5b731B7804ad"
export RPC="https://sepolia.base.org"
```

---

## Agent API (HTTP)

The API is **intent-building** — it returns `{ to, data, value }` calldata that a wallet signs and broadcasts. The server never holds private keys.

### Create a pending ETH transfer

```bash
curl -s -X POST "$BASE_URL/api/transfers" \
  -H "Content-Type: application/json" \
  -d '{
    "sender": "0xSENDER_ADDRESS",
    "receiver": "0xRECEIVER_ADDRESS",
    "amountEth": "0.001",
    "expiryMinutes": 60
  }'
```

**Response:**
```json
{
  "id": "0x...",
  "to": "0xf683...eF9",
  "data": "0x...",
  "value": "1000000000000000",
  "secret": "0x...",
  "shortCode": "XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XX",
  "commit": "0x..."
}
```

The agent must **securely store `secret`** — it is returned only once, never persisted server-side. Then broadcast the transaction: `{ to, data, value }`.

### List transfers for a user

```bash
curl -s "$BASE_URL/api/transfers?user=0xADDRESS"
```

**Response:**
```json
{
  "transfers": [
    {
      "id": "0x...",
      "sender": "0x...",
      "receiver": "0x...",
      "amount": "1000000000000000",
      "expiry": 1712966400,
      "status": 1
    }
  ]
}
```

Status codes: `0` = None, `1` = Pending, `2` = Claimed, `3` = Cancelled.

### Read a single transfer

```bash
curl -s "$BASE_URL/api/transfers/0xTRANSFER_ID"
```

### Build a claim intent

```bash
curl -s -X POST "$BASE_URL/api/transfers/0xTRANSFER_ID/claim" \
  -H "Content-Type: application/json" \
  -d '{ "secret": "0xSECRET_BYTES32" }'
```

**Response:** `{ "to": "0x...", "data": "0x..." }` — receiver signs and broadcasts.

### Build a cancel intent

```bash
curl -s -X POST "$BASE_URL/api/transfers/0xTRANSFER_ID/cancel"
```

**Response:** `{ "to": "0x...", "data": "0x..." }` — sender signs and broadcasts.

---

## Direct on-chain via `cast` (Foundry)

For agents with direct key access, skip the API and call the contract directly.

### Create

```bash
# Generate a 32-byte secret
SECRET=$(cast keccak $(cast abi-encode "f(uint256)" $(date +%s%N)))

# Preview the transfer ID
ID=$(cast call $CONTRACT \
  "previewId(address,address,address,uint256)(bytes32)" \
  $SENDER $RECEIVER 0x0000000000000000000000000000000000000000 $(cast to-wei 0.001) \
  --rpc-url $RPC)

# Compute commitment: keccak256(abi.encode(id, secret))
COMMIT=$(cast keccak $(cast abi-encode "f(bytes32,bytes32)" $ID $SECRET))

# Expiry: 1 hour from now
EXPIRY=$(($(date +%s) + 3600))

# Send the createETH transaction
cast send $CONTRACT \
  "createETH(address,bytes32,uint64)" \
  $RECEIVER $COMMIT $EXPIRY \
  --value 0.001ether \
  --private-key $SENDER_PK \
  --rpc-url $RPC
```

### Claim

```bash
# Receiver signs with their key + the secret from the sender
cast send $CONTRACT \
  "claim(bytes32,bytes32)" \
  $ID $SECRET \
  --private-key $RECEIVER_PK \
  --rpc-url $RPC
```

### Cancel

```bash
# Sender cancels — allowed any time while Pending
cast send $CONTRACT \
  "cancel(bytes32)" \
  $ID \
  --private-key $SENDER_PK \
  --rpc-url $RPC
```

### Read transfer state

```bash
cast call $CONTRACT \
  "getTransfer(bytes32)((address,address,address,uint256,bytes32,uint64,uint8))" \
  $ID \
  --rpc-url $RPC
```

---

## LLM Agent Integration Pattern

An LLM agent orchestrating transfers should follow this flow:

```
1. User says "send 0.01 ETH to 0xBob"
2. Agent calls POST /api/transfers → gets { id, to, data, value, secret }
3. Agent presents the intent to the user for signing (NEVER sign on behalf)
4. User signs via their wallet → tx confirmed
5. Agent stores { id, secret } in secure session state
6. Agent sends shortCode to receiver via DM / in-app message
7. Receiver calls POST /api/transfers/:id/claim with { secret }
8. Receiver signs the claim tx
9. Done — agent can verify via GET /api/transfers/:id (status == 2)
```

**Security rules for agents:**
- Never log or persist the `secret` beyond the session
- Never sign transactions — only build intents for user signing
- Always confirm receiver address with the user before creating
- Check transfer status before attempting claim/cancel
