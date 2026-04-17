"use client";

import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { WagmiProvider } from "wagmi";
import { config } from "./lib/wagmi";
import {
  createContext,
  useContext,
  useState,
  useEffect,
  type ReactNode,
} from "react";
import { sdk } from "@farcaster/miniapp-sdk";

type FarcasterContextType = {
  context: Awaited<typeof sdk.context> | null;
  isLoaded: boolean;
};

const FarcasterContext = createContext<FarcasterContextType>({
  context: null,
  isLoaded: false,
});

export function useFarcaster() {
  return useContext(FarcasterContext);
}

export function Providers({ children }: { children: ReactNode }) {
  const [queryClient] = useState(() => new QueryClient());
  const [isLoaded, setIsLoaded] = useState(false);
  const [fcContext, setFcContext] = useState<FarcasterContextType["context"]>(null);

  useEffect(() => {
    const load = async () => {
      try {
        const ctx = await sdk.context;
        setFcContext(ctx ?? null);
      } catch {
        // Not running inside Warpcast — context unavailable
      }
      sdk.actions.ready();
      setIsLoaded(true);
    };

    if (!isLoaded) {
      load();
    }
  }, [isLoaded]);

  return (
    <FarcasterContext.Provider value={{ context: fcContext, isLoaded }}>
      <WagmiProvider config={config}>
        <QueryClientProvider client={queryClient}>{children}</QueryClientProvider>
      </WagmiProvider>
    </FarcasterContext.Provider>
  );
}
