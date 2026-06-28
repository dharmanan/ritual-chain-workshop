import type { Address } from "viem";

/**
 * Ritual's prepaid-fee escrow. The LLM async precompile (`0x…0802`) charges the
 * caller's RitualWallet balance, and requires the funds to stay *locked* for
 * long enough to cover the async TEE callback. Without enough balance + lock
 * duration, `judgeAll` reverts with errors like "insufficient lock duration".
 *
 * This is a fixed protocol contract, so the address is hard-coded (not env).
 */
export const RITUAL_WALLET: Address = "0x532F0dF0896F353d8C3DD8cc134e8129DA2a3948";

export const ritualWalletAbi = [
  {
    name: "deposit",
    type: "function",
    stateMutability: "payable",
    inputs: [{ name: "lockDuration", type: "uint256" }],
    outputs: [],
  },
  {
    name: "balanceOf",
    type: "function",
    stateMutability: "view",
    inputs: [{ name: "user", type: "address" }],
    outputs: [{ type: "uint256" }],
  },
  {
    name: "lockUntil",
    type: "function",
    stateMutability: "view",
    inputs: [{ name: "user", type: "address" }],
    outputs: [{ type: "uint256" }],
  },
] as const;
