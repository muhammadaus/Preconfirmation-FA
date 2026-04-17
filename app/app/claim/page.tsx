"use client";

import { Suspense, useState, useEffect, useCallback } from "react";
import { useSearchParams } from "next/navigation";
import { useAccount, useWriteContract, useWaitForTransactionReceipt, useReadContract } from "wagmi";
import { formatEther, type Hex } from "viem";
import {
  PENDING_TRANSFERS_ADDRESS,
  pendingTransfersAbi,
} from "../lib/contract";
import { shortCodeToSecret } from "../lib/secret";
import Link from "next/link";

// Status enum matching the contract
const STATUS_LABELS: Record<number, string> = {
  0: "Not Found",
  1: "Pending",
  2: "Claimed",
  3: "Cancelled",
};

export default function ClaimPage() {
  return (
    <Suspense fallback={<div className="flex-1 flex items-center justify-center text-gray-400">Loading...</div>}>
      <ClaimInner />
    </Suspense>
  );
}

function ClaimInner() {
  const { address, isConnected } = useAccount();
  const searchParams = useSearchParams();

  const [transferId, setTransferId] = useState("");
  const [secret, setSecret] = useState("");
  const [codeInput, setCodeInput] = useState("");

  // Read the transfer ID from ?id= query param
  useEffect(() => {
    const id = searchParams.get("id");
    if (id) setTransferId(id);
  }, [searchParams]);

  // Read the secret from the URL fragment (#s=...)
  // Fragments are never sent to the server — this is the security property.
  useEffect(() => {
    const hash = window.location.hash;
    const match = hash.match(/s=([0-9a-fA-Fx]+)/);
    if (match) setSecret(match[1]);
  }, []);

  // When user types a short code, convert to secret
  const handleCodePaste = useCallback((code: string) => {
    setCodeInput(code);
    if (code.replace(/-/g, "").length >= 26) {
      try {
        const s = shortCodeToSecret(code);
        setSecret(s);
      } catch {
        // invalid code — will be caught at claim time
      }
    }
  }, []);

  // Read transfer data from chain
  const { data: transfer } = useReadContract({
    address: PENDING_TRANSFERS_ADDRESS,
    abi: pendingTransfersAbi,
    functionName: "getTransfer",
    args: transferId ? [transferId as Hex] : undefined,
    query: { enabled: !!transferId },
  });

  const { writeContract, data: txHash, isPending: isSigning } = useWriteContract();
  const { isLoading: isConfirming, isSuccess } = useWaitForTransactionReceipt({
    hash: txHash,
  });

  const handleClaim = useCallback(() => {
    if (!transferId || !secret) return;
    writeContract({
      address: PENDING_TRANSFERS_ADDRESS,
      abi: pendingTransfersAbi,
      functionName: "claim",
      args: [transferId as Hex, secret as Hex],
    });
  }, [transferId, secret, writeContract]);

  if (!isConnected) {
    return (
      <main className="flex flex-col items-center justify-center flex-1 p-6">
        <p className="text-gray-500">Connect your wallet to claim.</p>
        <Link href="/" className="mt-4 text-blue-600 hover:underline">Go home</Link>
      </main>
    );
  }

  if (isSuccess) {
    return (
      <main className="flex flex-col items-center justify-center flex-1 p-6 gap-4">
        <h1 className="text-2xl font-bold text-green-600">Claimed!</h1>
        <p className="text-gray-500">Funds have been transferred to your wallet.</p>
        <Link href="/transfers" className="text-blue-600 hover:underline">View transfers</Link>
      </main>
    );
  }

  const status = transfer ? Number(transfer.status) : undefined;
  const amount = transfer ? transfer.amount : undefined;
  const sender = transfer ? transfer.sender : undefined;
  const expiry = transfer ? Number(transfer.expiry) : undefined;
  const isPending = status === 1;
  const isExpired = expiry ? Date.now() / 1000 > expiry : false;

  return (
    <main className="flex flex-col items-center flex-1 p-6 gap-6 max-w-lg mx-auto">
      <h1 className="text-2xl font-bold">Claim Transfer</h1>

      {/* Transfer ID input (auto-filled from URL) */}
      <div className="w-full space-y-4">
        <div>
          <label className="block text-sm font-medium text-gray-700 mb-1">Transfer ID</label>
          <input
            type="text"
            placeholder="0x..."
            value={transferId}
            onChange={(e) => setTransferId(e.target.value)}
            className="w-full px-4 py-2 border rounded-lg font-mono text-xs focus:ring-2 focus:ring-green-500 focus:border-transparent"
          />
        </div>

        {/* Short code input (for manual entry) */}
        {!secret && (
          <div>
            <label className="block text-sm font-medium text-gray-700 mb-1">
              Short Code (from sender)
            </label>
            <input
              type="text"
              placeholder="XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XX"
              value={codeInput}
              onChange={(e) => handleCodePaste(e.target.value)}
              className="w-full px-4 py-2 border rounded-lg font-mono text-sm focus:ring-2 focus:ring-green-500 focus:border-transparent"
            />
          </div>
        )}

        {secret && (
          <p className="text-sm text-green-600">Secret loaded from link</p>
        )}

        {/* Transfer details */}
        {transfer && status !== undefined && (
          <div className="bg-gray-50 rounded-xl p-4 space-y-2">
            <div className="flex justify-between text-sm">
              <span className="text-gray-500">Status</span>
              <span className={isPending ? "text-yellow-600 font-medium" : "text-gray-700"}>
                {STATUS_LABELS[status] ?? "Unknown"}
              </span>
            </div>
            {amount !== undefined && (
              <div className="flex justify-between text-sm">
                <span className="text-gray-500">Amount</span>
                <span className="font-mono">{formatEther(amount)} ETH</span>
              </div>
            )}
            {sender && (
              <div className="flex justify-between text-sm">
                <span className="text-gray-500">From</span>
                <span className="font-mono text-xs">{sender.slice(0, 6)}...{sender.slice(-4)}</span>
              </div>
            )}
            {expiry && (
              <div className="flex justify-between text-sm">
                <span className="text-gray-500">Expires</span>
                <span className={isExpired ? "text-red-500" : ""}>
                  {new Date(expiry * 1000).toLocaleString()}
                  {isExpired && " (expired)"}
                </span>
              </div>
            )}
          </div>
        )}

        {/* Error states */}
        {status === 0 && transferId && (
          <p className="text-red-500 text-sm">Transfer not found. Check the ID.</p>
        )}
        {status === 2 && <p className="text-gray-500 text-sm">Already claimed.</p>}
        {status === 3 && <p className="text-gray-500 text-sm">Cancelled by sender.</p>}
        {isExpired && isPending && (
          <p className="text-red-500 text-sm">Transfer has expired. Contact the sender.</p>
        )}

        <button
          onClick={handleClaim}
          disabled={!isPending || !secret || isExpired || isSigning || isConfirming}
          className="w-full px-6 py-3 bg-green-600 text-white rounded-lg hover:bg-green-700 transition font-medium disabled:opacity-50 disabled:cursor-not-allowed"
        >
          {isSigning
            ? "Sign in wallet..."
            : isConfirming
              ? "Confirming..."
              : "Claim Funds"}
        </button>
      </div>

      <Link href="/" className="text-sm text-gray-400 hover:text-gray-600">Back</Link>
    </main>
  );
}
