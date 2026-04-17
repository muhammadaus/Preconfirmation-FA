"use client";

import { useState, useCallback } from "react";
import { useAccount, useWriteContract, useWaitForTransactionReceipt, useReadContract } from "wagmi";
import { parseEther, isAddress, type Hex } from "viem";
import { base } from "viem/chains";
import { QRCodeSVG } from "qrcode.react";
import {
  PENDING_TRANSFERS_ADDRESS,
  pendingTransfersAbi,
} from "../lib/contract";
import { generateSecret, computeCommit, secretToShortCode } from "../lib/secret";
import Link from "next/link";

type TransferResult = {
  id: Hex;
  secret: Hex;
  shortCode: string;
  claimUrl: string;
};

export default function SendPage() {
  const { address, isConnected } = useAccount();

  const [receiver, setReceiver] = useState("");
  const [amount, setAmount] = useState("");
  const [expiryMinutes, setExpiryMinutes] = useState("60");
  const [result, setResult] = useState<TransferResult | null>(null);
  const [error, setError] = useState<string | null>(null);

  // Validate inputs before attempting contract read
  const isValidReceiver = isAddress(receiver);
  const parsedAmount = (() => { try { return amount ? parseEther(amount) : 0n; } catch { return null; } })();
  const canPreview = !!address && isValidReceiver && !!amount && parsedAmount !== null && parsedAmount > 0n;

  // Preview the ID before sending — pinned to Base mainnet
  const { data: previewId, isLoading: isPreviewLoading, error: previewError } = useReadContract({
    address: PENDING_TRANSFERS_ADDRESS,
    abi: pendingTransfersAbi,
    functionName: "previewId",
    args: canPreview
      ? [address, receiver as Hex, "0x0000000000000000000000000000000000000000" as Hex, parsedAmount!]
      : undefined,
    chainId: base.id,
    query: { enabled: canPreview },
  });

  const { writeContract, data: txHash, isPending: isSigning } = useWriteContract();
  const { isLoading: isConfirming, isSuccess } = useWaitForTransactionReceipt({
    hash: txHash,
  });

  const handleSend = useCallback(() => {
    setError(null);
    if (!address) { setError("Wallet not connected"); return; }
    if (!receiver) { setError("Enter a receiver address"); return; }
    if (!isValidReceiver) { setError("Invalid receiver address"); return; }
    if (!amount) { setError("Enter an amount"); return; }
    if (parsedAmount === null) { setError("Invalid amount format"); return; }
    if (parsedAmount === 0n) { setError("Amount must be greater than 0"); return; }
    if (isPreviewLoading) { setError("Loading transfer ID, try again in a moment..."); return; }
    if (previewError) { setError(`Contract read failed: ${previewError.message}`); return; }
    if (!previewId) { setError("Could not compute transfer ID — try again"); return; }

    try {
      const secret = generateSecret();
      const commit = computeCommit(previewId as Hex, secret);
      const expirySeconds = Math.floor(Date.now() / 1000) + parseInt(expiryMinutes) * 60;

      // Store the secret + id so we can show it after tx confirms
      const shortCode = secretToShortCode(secret);
      const claimUrl = `${window.location.origin}/claim?id=${previewId}#s=${secret}`;

      setResult({
        id: previewId as Hex,
        secret,
        shortCode,
        claimUrl,
      });

      writeContract({
        address: PENDING_TRANSFERS_ADDRESS,
        abi: pendingTransfersAbi,
        functionName: "createETH",
        args: [receiver as Hex, commit, BigInt(expirySeconds)],
        value: parseEther(amount),
      });
    } catch (e: unknown) {
      setError(e instanceof Error ? e.message : "Unknown error");
    }
  }, [address, receiver, isValidReceiver, amount, parsedAmount, previewId, previewError, isPreviewLoading, expiryMinutes, writeContract]);

  if (!isConnected) {
    return (
      <main className="flex flex-col items-center justify-center flex-1 p-6">
        <p className="text-gray-500">Connect your wallet to send.</p>
        <Link href="/" className="mt-4 text-blue-600 hover:underline">
          Go home
        </Link>
      </main>
    );
  }

  // Post-confirmation view: show the secret / QR / short code
  if (isSuccess && result) {
    return (
      <main className="flex flex-col items-center flex-1 p-6 gap-6 max-w-lg mx-auto">
        <h1 className="text-2xl font-bold text-green-600">Transfer Created</h1>
        <p className="text-sm text-gray-500 text-center">
          Share this code with the receiver. They need it to claim the funds.
        </p>

        <div className="bg-gray-50 rounded-xl p-6 w-full space-y-4">
          <div>
            <label className="text-xs text-gray-400 uppercase tracking-wide">Short Code</label>
            <p className="font-mono text-lg tracking-wider select-all">{result.shortCode}</p>
          </div>

          <div>
            <label className="text-xs text-gray-400 uppercase tracking-wide">Transfer ID</label>
            <p className="font-mono text-xs break-all select-all">{result.id}</p>
          </div>

          <div className="flex justify-center">
            <QRCodeSVG value={result.claimUrl} size={200} />
          </div>

          <div>
            <label className="text-xs text-gray-400 uppercase tracking-wide">Claim Link</label>
            <p className="font-mono text-xs break-all select-all">{result.claimUrl}</p>
          </div>
        </div>

        <Link href="/send" onClick={() => setResult(null)} className="text-blue-600 hover:underline">
          Create another transfer
        </Link>
      </main>
    );
  }

  return (
    <main className="flex flex-col items-center flex-1 p-6 gap-6 max-w-lg mx-auto">
      <h1 className="text-2xl font-bold">Create Pending Transfer</h1>

      <div className="w-full space-y-4">
        <div>
          <label className="block text-sm font-medium text-gray-700 mb-1">
            Receiver Address
          </label>
          <input
            type="text"
            placeholder="0x..."
            value={receiver}
            onChange={(e) => setReceiver(e.target.value)}
            className="w-full px-4 py-2 border rounded-lg font-mono text-sm focus:ring-2 focus:ring-blue-500 focus:border-transparent"
          />
        </div>

        <div>
          <label className="block text-sm font-medium text-gray-700 mb-1">
            Amount (ETH)
          </label>
          <input
            type="text"
            placeholder="0.01"
            value={amount}
            onChange={(e) => setAmount(e.target.value)}
            className="w-full px-4 py-2 border rounded-lg font-mono text-sm focus:ring-2 focus:ring-blue-500 focus:border-transparent"
          />
        </div>

        <div>
          <label className="block text-sm font-medium text-gray-700 mb-1">
            Expiry (minutes)
          </label>
          <select
            value={expiryMinutes}
            onChange={(e) => setExpiryMinutes(e.target.value)}
            className="w-full px-4 py-2 border rounded-lg text-sm focus:ring-2 focus:ring-blue-500"
          >
            <option value="10">10 min</option>
            <option value="30">30 min</option>
            <option value="60">1 hour</option>
            <option value="360">6 hours</option>
            <option value="1440">24 hours</option>
            <option value="10080">7 days</option>
          </select>
        </div>

        {error && (
          <p className="text-red-500 text-sm">{error}</p>
        )}

        <button
          onClick={handleSend}
          disabled={isSigning || isConfirming || !receiver || !amount || isPreviewLoading}
          className="w-full px-6 py-3 bg-blue-600 text-white rounded-lg hover:bg-blue-700 transition font-medium disabled:opacity-50 disabled:cursor-not-allowed"
        >
          {isSigning
            ? "Sign in wallet..."
            : isConfirming
              ? "Confirming..."
              : isPreviewLoading
                ? "Preparing..."
                : "Create Transfer"}
        </button>
      </div>

      <Link href="/" className="text-sm text-gray-400 hover:text-gray-600">
        Back
      </Link>
    </main>
  );
}
