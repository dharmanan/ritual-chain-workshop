import type { Address } from "viem";
import aiJudgeAbi from "@/abi/AIJudge";

/**
 * Central place for the on-chain config the UI needs.
 * Everything is read from `NEXT_PUBLIC_*` env vars so the same build can be
 * pointed at different Ritual deployments without code changes.
 */

export const aiJudgeAbiConst = aiJudgeAbi;

const rawAddress = process.env.NEXT_PUBLIC_CONTRACT_ADDRESS?.trim();

/** Deployed SimpleAIBountyJudge address, or `undefined` if not configured. */
export const contractAddress: Address | undefined =
  rawAddress && /^0x[0-9a-fA-F]{40}$/.test(rawAddress)
    ? (rawAddress as Address)
    : undefined;

/** True when the contract address env var is present and well-formed. */
export const isContractConfigured = Boolean(contractAddress);

/** Ritual LLM executor / callback address used when encoding `judgeAll` input. */
export const executorAddress: Address =
  (process.env.NEXT_PUBLIC_RITUAL_EXECUTOR_ADDRESS?.trim() as Address | undefined) ??
  "0x0000000000000000000000000000000000000802";

export const ritualChainId = Number(
  process.env.NEXT_PUBLIC_RITUAL_CHAIN_ID ?? "1979",
);

export const ritualRpcUrl =
  process.env.NEXT_PUBLIC_RITUAL_RPC_URL ?? "https://rpc.ritualfoundation.org";
