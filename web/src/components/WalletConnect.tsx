"use client";

import { useState } from "react";
import {
  useAccount,
  useConnect,
  useDisconnect,
  useChainId,
  useSwitchChain,
} from "wagmi";
import { ritualChain } from "@/config/wagmi";
import { shortenAddress } from "@/lib/format";
import { Button, Badge } from "@/components/ui";

export function WalletConnect() {
  const { address, isConnected } = useAccount();
  const { connect, connectors, isPending } = useConnect();
  const { disconnect } = useDisconnect();
  const chainId = useChainId();
  const { switchChain } = useSwitchChain();
  const [open, setOpen] = useState(false);

  const wrongChain = isConnected && chainId !== ritualChain.id;

  if (isConnected && address) {
    return (
      <div className="flex items-center gap-2">
        {wrongChain ? (
          <Button
            variant="secondary"
            onClick={() => switchChain({ chainId: ritualChain.id })}
          >
            Switch to {ritualChain.name}
          </Button>
        ) : (
          <Badge tone="green">{ritualChain.name}</Badge>
        )}
        <Button variant="secondary" onClick={() => disconnect()}>
          {shortenAddress(address)}
        </Button>
      </div>
    );
  }

  // Dedupe connectors by name (injected + metaMask can overlap).
  const seen = new Set<string>();
  const list = connectors.filter((c) => {
    if (seen.has(c.name)) return false;
    seen.add(c.name);
    return true;
  });

  return (
    <div className="relative">
      <Button onClick={() => setOpen((v) => !v)} disabled={isPending}>
        {isPending ? "Connecting…" : "Connect Wallet"}
      </Button>
      {open && (
        <div className="absolute right-0 z-20 mt-2 w-52 overflow-hidden rounded-xl border border-white/10 bg-zinc-900 shadow-xl">
          {list.length === 0 && (
            <div className="px-3 py-2 text-xs text-zinc-500">
              No wallet connectors found.
            </div>
          )}
          {list.map((connector) => (
            <button
              key={connector.uid}
              onClick={() => {
                connect({ connector });
                setOpen(false);
              }}
              className="block w-full px-3 py-2 text-left text-sm text-zinc-200 hover:bg-white/10"
            >
              {connector.name}
            </button>
          ))}
        </div>
      )}
    </div>
  );
}
