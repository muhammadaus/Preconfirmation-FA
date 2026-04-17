"use client";

import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { WagmiProvider } from "wagmi";
import { config } from "./lib/wagmi";
import { useState, useEffect, type ReactNode } from "react";
import { sdk } from "@farcaster/miniapp-sdk";

export function Providers({ children }: { children: ReactNode }) {
  const [queryClient] = useState(() => new QueryClient());

  useEffect(() => {
    sdk.actions.ready();
  }, []);

  return (
    <WagmiProvider config={config}>
      <QueryClientProvider client={queryClient}>{children}</QueryClientProvider>
    </WagmiProvider>
  );
}
