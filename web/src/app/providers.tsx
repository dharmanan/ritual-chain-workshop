"use client";

import { useState } from "react";
import { WagmiProvider } from "wagmi";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { config } from "@/config/wagmi";

/**
 * Client-side provider tree. Next.js App Router layouts are Server Components,
 * so wagmi + React Query (which rely on client state/context) must live in a
 * dedicated `"use client"` wrapper that the server layout renders.
 */
export function Providers({ children }: { children: React.ReactNode }) {
  // Keep the QueryClient stable across re-renders within this client boundary.
  const [queryClient] = useState(() => new QueryClient());

  return (
    <WagmiProvider config={config}>
      <QueryClientProvider client={queryClient}>{children}</QueryClientProvider>
    </WagmiProvider>
  );
}
