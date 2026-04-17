"use client";

import Link from "next/link";
import { useEffect } from "react";
import { useAccount, useConnect, useDisconnect } from "wagmi";
import { config } from "./lib/wagmi";
import { useFarcaster } from "./providers";

export default function Home() {
  const { address, isConnected } = useAccount();
  const { connect, connectors } = useConnect();
  const { disconnect } = useDisconnect();
  const { isLoaded, context } = useFarcaster();

  // Auto-connect when running inside Warpcast
  useEffect(() => {
    if (isLoaded && context && !isConnected) {
      connect({ connector: config.connectors[0] });
    }
  }, [isLoaded, context, isConnected, connect]);

  // Show loading while SDK initializes inside Warpcast
  if (!isLoaded) {
    return (
      <main className="flex flex-col items-center justify-center flex-1 p-6">
        <p className="text-gray-400">Loading...</p>
      </main>
    );
  }

  return (
    <main className="flex flex-col items-center justify-center flex-1 p-6 gap-8">
      <div className="text-center space-y-2">
        <h1 className="text-3xl font-bold tracking-tight">Preconfirmation</h1>
        <p className="text-gray-500 max-w-md">
          Safe pending transfers with secret-based confirmation. Never
          irreversibly push funds to a pasted address again.
        </p>
      </div>

      {!isConnected ? (
        <div className="space-y-3">
          {connectors.map((connector) => (
            <button
              key={connector.uid}
              onClick={() => connect({ connector })}
              className="w-full px-6 py-3 bg-blue-600 text-white rounded-lg hover:bg-blue-700 transition min-h-[44px]"
            >
              Connect with {connector.name}
            </button>
          ))}
        </div>
      ) : (
        <div className="flex flex-col items-center gap-4">
          <p className="text-sm text-gray-500 font-mono">
            {address?.slice(0, 6)}...{address?.slice(-4)}
          </p>

          <div className="flex flex-col sm:flex-row gap-3 w-full max-w-sm">
            <Link
              href="/send"
              className="flex-1 px-6 py-3 bg-blue-600 text-white rounded-lg hover:bg-blue-700 transition font-medium text-center min-h-[44px]"
            >
              Send
            </Link>
            <Link
              href="/claim"
              className="flex-1 px-6 py-3 bg-green-600 text-white rounded-lg hover:bg-green-700 transition font-medium text-center min-h-[44px]"
            >
              Claim
            </Link>
            <Link
              href="/transfers"
              className="flex-1 px-6 py-3 bg-gray-200 text-gray-800 rounded-lg hover:bg-gray-300 transition font-medium text-center min-h-[44px]"
            >
              History
            </Link>
          </div>

          <button
            onClick={() => disconnect()}
            className="text-sm text-gray-400 hover:text-gray-600 transition min-h-[44px]"
          >
            Disconnect
          </button>
        </div>
      )}
    </main>
  );
}
