"use client";

import { useCallback } from "react";
import { useBlockNumber, useReadContract } from "wagmi";
import { RITUAL_WALLET, ritualWalletAbi } from "@/abi/RitualWallet";
import { ritualChain } from "@/config/wagmi";
import { deriveStatus, type RitualWalletStatus } from "@/lib/ritualWallet";

type Result = Partial<RitualWalletStatus> & {
  isLoading: boolean;
  /** True once all three reads (balance, lock, block) have landed. */
  hasData: boolean;
  refetch: () => void;
};

/**
 * Live RitualWallet funding status for `user` (the *connected* wallet, not the
 * bounty contract). Built on wagmi reads + the live block number so render stays
 * pure — no `setState` in effects. Reads are disabled until a user is present.
 */
export function useRitualWalletStatus(user?: `0x${string}`): Result {
  const enabled = Boolean(user);

  const balanceQ = useReadContract({
    address: RITUAL_WALLET,
    abi: ritualWalletAbi,
    functionName: "balanceOf",
    args: user ? [user] : undefined,
    chainId: ritualChain.id,
    query: { enabled, refetchInterval: 15_000 },
  });

  const lockQ = useReadContract({
    address: RITUAL_WALLET,
    abi: ritualWalletAbi,
    functionName: "lockUntil",
    args: user ? [user] : undefined,
    chainId: ritualChain.id,
    query: { enabled, refetchInterval: 15_000 },
  });

  const blockQ = useBlockNumber({
    chainId: ritualChain.id,
    query: { enabled, refetchInterval: 15_000 },
  });

  const refetch = useCallback(() => {
    void balanceQ.refetch();
    void lockQ.refetch();
    void blockQ.refetch();
  }, [balanceQ, lockQ, blockQ]);

  const balance = balanceQ.data;
  const lockUntil = lockQ.data;
  const currentBlock = blockQ.data;

  const isLoading = balanceQ.isLoading || lockQ.isLoading || blockQ.isLoading;
  const hasData =
    balance !== undefined && lockUntil !== undefined && currentBlock !== undefined;

  if (!hasData) {
    return { isLoading, hasData: false, refetch };
  }

  return { ...deriveStatus(balance, lockUntil, currentBlock), isLoading, hasData: true, refetch };
}
