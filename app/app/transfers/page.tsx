"use client";

import { useState, useEffect } from "react";
import { useAccount, useWriteContract, useWaitForTransactionReceipt } from "wagmi";
import { createPublicClient, http, formatEther, type Hex, parseAbiItem } from "viem";
import { base } from "viem/chains";
import {
  PENDING_TRANSFERS_ADDRESS,
  pendingTransfersAbi,
  DEPLOY_BLOCK,
  LOG_BLOCK_RANGE,
} from "../lib/contract";
import Link from "next/link";

type Transfer = {
  id: Hex;
  sender: string;
  receiver: string;
  amount: bigint;
  expiry: number;
  status: number;
  isSender: boolean;
};

const STATUS_LABELS: Record<number, string> = {
  0: "Not Found",
  1: "Pending",
  2: "Claimed",
  3: "Cancelled",
};

const STATUS_COLORS: Record<number, string> = {
  1: "text-yellow-600 bg-yellow-50",
  2: "text-green-600 bg-green-50",
  3: "text-gray-500 bg-gray-100",
};

const publicClient = createPublicClient({
  chain: base,
  transport: http(),
});

export default function TransfersPage() {
  const { address, isConnected } = useAccount();
  const [transfers, setTransfers] = useState<Transfer[]>([]);
  const [loading, setLoading] = useState(false);
  const [cancellingId, setCancellingId] = useState<Hex | null>(null);

  const { writeContract, data: cancelTxHash } = useWriteContract();
  const { isSuccess: cancelSuccess } = useWaitForTransactionReceipt({
    hash: cancelTxHash,
  });

  // Refresh after successful cancel
  useEffect(() => {
    if (cancelSuccess) {
      setCancellingId(null);
      loadTransfers();
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [cancelSuccess]);

  const loadTransfers = async () => {
    if (!address) return;
    setLoading(true);

    try {
      const latestBlock = await publicClient.getBlockNumber();
      const event = parseAbiItem(
        "event TransferCreated(bytes32 indexed id, address indexed sender, address indexed receiver, address token, uint256 amount, bytes32 commit, uint64 expiry)"
      );

      // Paginate getLogs in chunks to respect public RPC limits
      const fetchLogs = async (args: Record<string, Hex>) => {
        const allLogs = [];
        for (let from = DEPLOY_BLOCK; from <= latestBlock; from += LOG_BLOCK_RANGE + 1n) {
          const to = from + LOG_BLOCK_RANGE > latestBlock ? latestBlock : from + LOG_BLOCK_RANGE;
          const logs = await publicClient.getLogs({
            address: PENDING_TRANSFERS_ADDRESS,
            event,
            args,
            fromBlock: from,
            toBlock: to,
          });
          allLogs.push(...logs);
        }
        return allLogs;
      };

      // Fetch TransferCreated events where user is sender OR receiver
      const [sentLogs, receivedLogs] = await Promise.all([
        fetchLogs({ sender: address }),
        fetchLogs({ receiver: address }),
      ]);

      // Merge and deduplicate (a self-transfer appears in both)
      const allLogs = [...sentLogs, ...receivedLogs];
      const seen = new Set<string>();
      const unique = allLogs.filter((log) => {
        const id = log.args.id as string;
        if (seen.has(id)) return false;
        seen.add(id);
        return true;
      });

      // Fetch current on-chain status for each
      const results: Transfer[] = await Promise.all(
        unique.map(async (log) => {
          const id = log.args.id as Hex;
          const data = await publicClient.readContract({
            address: PENDING_TRANSFERS_ADDRESS,
            abi: pendingTransfersAbi,
            functionName: "getTransfer",
            args: [id],
          });
          const d = data as {
            sender: string;
            receiver: string;
            token: string;
            amount: bigint;
            commit: Hex;
            expiry: bigint;
            status: number;
          };
          return {
            id,
            sender: d.sender,
            receiver: d.receiver,
            amount: d.amount,
            expiry: Number(d.expiry),
            status: Number(d.status),
            isSender: d.sender.toLowerCase() === address.toLowerCase(),
          };
        })
      );

      // Sort by expiry descending (newest first)
      results.sort((a, b) => b.expiry - a.expiry);
      setTransfers(results);
    } catch (e) {
      console.error("Failed to load transfers:", e);
    } finally {
      setLoading(false);
    }
  };

  // Load on mount and when address changes
  useEffect(() => {
    loadTransfers();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [address]);

  const handleCancel = (id: Hex) => {
    setCancellingId(id);
    writeContract({
      address: PENDING_TRANSFERS_ADDRESS,
      abi: pendingTransfersAbi,
      functionName: "cancel",
      args: [id],
    });
  };

  if (!isConnected) {
    return (
      <main className="flex flex-col items-center justify-center flex-1 p-6">
        <p className="text-gray-500">Connect your wallet to view transfers.</p>
        <Link href="/" className="mt-4 text-blue-600 hover:underline">Go home</Link>
      </main>
    );
  }

  return (
    <main className="flex flex-col items-center flex-1 p-6 gap-6 max-w-2xl mx-auto w-full">
      <div className="flex items-center justify-between w-full">
        <h1 className="text-2xl font-bold">Your Transfers</h1>
        <button
          onClick={loadTransfers}
          disabled={loading}
          className="text-sm text-blue-600 hover:underline disabled:opacity-50"
        >
          {loading ? "Loading..." : "Refresh"}
        </button>
      </div>

      {transfers.length === 0 && !loading && (
        <p className="text-gray-400">No transfers yet.</p>
      )}

      <div className="w-full space-y-3">
        {transfers.map((t) => (
          <div
            key={t.id}
            className="border rounded-xl p-4 space-y-2"
          >
            <div className="flex items-center justify-between">
              <span className="text-xs text-gray-400">
                {t.isSender ? "Sent" : "Received"}
              </span>
              <span
                className={`text-xs px-2 py-0.5 rounded-full font-medium ${STATUS_COLORS[t.status] ?? ""}`}
              >
                {STATUS_LABELS[t.status] ?? "?"}
              </span>
            </div>

            <div className="flex items-center justify-between">
              <span className="font-mono text-lg">{formatEther(t.amount)} ETH</span>
              <span className="text-xs text-gray-400">
                Expires {new Date(t.expiry * 1000).toLocaleString()}
              </span>
            </div>

            <div className="text-xs font-mono text-gray-400 break-all">
              {t.isSender ? `To: ${t.receiver}` : `From: ${t.sender}`}
            </div>

            <div className="text-xs font-mono text-gray-300 break-all">
              ID: {t.id}
            </div>

            {/* Cancel button: only for sender, only if pending */}
            {t.isSender && t.status === 1 && (
              <button
                onClick={() => handleCancel(t.id)}
                disabled={cancellingId === t.id}
                className="mt-2 text-sm text-red-500 hover:text-red-700 transition disabled:opacity-50"
              >
                {cancellingId === t.id ? "Cancelling..." : "Cancel Transfer"}
              </button>
            )}
          </div>
        ))}
      </div>

      <Link href="/" className="text-sm text-gray-400 hover:text-gray-600">Back</Link>
    </main>
  );
}
