import { parseEther, type PublicClient } from "viem";
import { RITUAL_WALLET, ritualWalletAbi } from "@/abi/RitualWallet";

/**
 * Funding requirements for running an AI judging (`judgeAll`) transaction.
 * These mirror what the LLM precompile expects: enough RITUAL deposited, and
 * a lock that outlives the async callback by a comfortable buffer.
 */
export const MIN_LLM_BALANCE = parseEther("0.05");
/** How long (in blocks) the "Deposit LLM Fees" action locks funds for. */
export const LOCK_DURATION = 100_000n;
/** Lock must extend at least this many blocks past the current block. */
export const REQUIRED_TTL_BUFFER = 300n;
/** Amount sent with a single deposit. */
export const DEPOSIT_AMOUNT = parseEther("0.05");

export type RitualWalletStatus = {
  balance: bigint;
  lockUntil: bigint;
  currentBlock: bigint;
  hasEnoughBalance: boolean;
  hasEnoughLockDuration: boolean;
  /** Lock has already elapsed (or was never set). */
  lockExpired: boolean;
  ready: boolean;
};

/**
 * One-shot read of the connected wallet's RitualWallet funding state. Reads the
 * balance + lock against the *user* address (never the bounty contract) and
 * compares the lock to the live block number.
 */
export async function getRitualWalletStatus({
  publicClient,
  user,
}: {
  publicClient: PublicClient;
  user: `0x${string}`;
}): Promise<RitualWalletStatus> {
  const [balance, lockUntil, currentBlock] = await Promise.all([
    publicClient.readContract({
      address: RITUAL_WALLET,
      abi: ritualWalletAbi,
      functionName: "balanceOf",
      args: [user],
    }),
    publicClient.readContract({
      address: RITUAL_WALLET,
      abi: ritualWalletAbi,
      functionName: "lockUntil",
      args: [user],
    }),
    publicClient.getBlockNumber(),
  ]);

  return deriveStatus(balance, lockUntil, currentBlock);
}

/** Pure comparison shared by the helper and the React hook. */
export function deriveStatus(
  balance: bigint,
  lockUntil: bigint,
  currentBlock: bigint,
): RitualWalletStatus {
  const hasEnoughBalance = balance >= MIN_LLM_BALANCE;
  const hasEnoughLockDuration = lockUntil >= currentBlock + REQUIRED_TTL_BUFFER;
  const lockExpired = lockUntil <= currentBlock;
  return {
    balance,
    lockUntil,
    currentBlock,
    hasEnoughBalance,
    hasEnoughLockDuration,
    lockExpired,
    ready: hasEnoughBalance && hasEnoughLockDuration,
  };
}
