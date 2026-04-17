#!/usr/bin/env bash
# Preconfirmation-FA CLI Agent — wraps the Agent API for common flows.
#
# Usage:
#   ./agent.sh create <sender> <receiver> <amountEth> [expiryMinutes]
#   ./agent.sh list   <userAddress>
#   ./agent.sh read   <transferId>
#   ./agent.sh claim  <transferId> <secret>
#   ./agent.sh cancel <transferId>
#
# Environment:
#   BASE_URL  — deployed API root (default: http://localhost:3000)

set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:3000}"

usage() {
  echo "Usage:"
  echo "  $0 create <sender> <receiver> <amountEth> [expiryMinutes]"
  echo "  $0 list   <userAddress>"
  echo "  $0 read   <transferId>"
  echo "  $0 claim  <transferId> <secret>"
  echo "  $0 cancel <transferId>"
  exit 1
}

[ $# -lt 2 ] && usage

CMD="$1"
shift

case "$CMD" in
  create)
    [ $# -lt 3 ] && { echo "Error: create needs sender, receiver, amountEth"; exit 1; }
    SENDER="$1"; RECEIVER="$2"; AMOUNT="$3"; EXPIRY="${4:-60}"
    echo "Creating transfer: $AMOUNT ETH from $SENDER to $RECEIVER (expiry: ${EXPIRY}m)"
    RESP=$(curl -s -X POST "$BASE_URL/api/transfers" \
      -H "Content-Type: application/json" \
      -d "{\"sender\":\"$SENDER\",\"receiver\":\"$RECEIVER\",\"amountEth\":\"$AMOUNT\",\"expiryMinutes\":$EXPIRY}")
    echo "$RESP" | python3 -m json.tool 2>/dev/null || echo "$RESP"
    echo ""
    echo "--- IMPORTANT ---"
    echo "Store the 'secret' securely. Share the 'shortCode' with the receiver."
    echo "Sign and broadcast the { to, data, value } intent with your wallet."
    ;;

  list)
    USER="$1"
    echo "Listing transfers for $USER"
    curl -s "$BASE_URL/api/transfers?user=$USER" | python3 -m json.tool 2>/dev/null
    ;;

  read)
    ID="$1"
    echo "Reading transfer $ID"
    curl -s "$BASE_URL/api/transfers/$ID" | python3 -m json.tool 2>/dev/null
    ;;

  claim)
    [ $# -lt 2 ] && { echo "Error: claim needs transferId and secret"; exit 1; }
    ID="$1"; SECRET="$2"
    echo "Building claim intent for transfer $ID"
    RESP=$(curl -s -X POST "$BASE_URL/api/transfers/$ID/claim" \
      -H "Content-Type: application/json" \
      -d "{\"secret\":\"$SECRET\"}")
    echo "$RESP" | python3 -m json.tool 2>/dev/null || echo "$RESP"
    echo ""
    echo "Sign and broadcast the { to, data } intent with the RECEIVER wallet."
    ;;

  cancel)
    ID="$1"
    echo "Building cancel intent for transfer $ID"
    RESP=$(curl -s -X POST "$BASE_URL/api/transfers/$ID/cancel")
    echo "$RESP" | python3 -m json.tool 2>/dev/null || echo "$RESP"
    echo ""
    echo "Sign and broadcast the { to, data } intent with the SENDER wallet."
    ;;

  *)
    usage
    ;;
esac
