"use client";

import Link from "next/link";
import { useAccount, useConnect, useDisconnect } from "wagmi";

export default function Home() {
  const { address, isConnected } = useAccount();
  const { connect, connectors } = useConnect();
  const { disconnect } = useDisconnect();

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
              className="w-full px-6 py-3 bg-blue-600 text-white rounded-lg hover:bg-blue-700 transition"
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

          <div className="flex gap-3">
            <Link
              href="/send"
              className="px-6 py-3 bg-blue-600 text-white rounded-lg hover:bg-blue-700 transition font-medium"
            >
              Send
            </Link>
            <Link
              href="/claim"
              className="px-6 py-3 bg-green-600 text-white rounded-lg hover:bg-green-700 transition font-medium"
            >
              Claim
            </Link>
            <Link
              href="/transfers"
              className="px-6 py-3 bg-gray-200 text-gray-800 rounded-lg hover:bg-gray-300 transition font-medium"
            >
              History
            </Link>
          </div>

          <button
            onClick={() => disconnect()}
            className="text-sm text-gray-400 hover:text-gray-600 transition"
          >
            Disconnect
          </button>
        </div>
      )}
    </main>
  );
}
