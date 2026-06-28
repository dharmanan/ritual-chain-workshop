# AI Bounty Judge

A workshop-demo frontend for the **Ritual Chain** `SimpleAIBountyJudge` contract.

> Submit answers to a bounty. After the deadline, Ritual AI ranks all
> submissions. The bounty owner finalizes the winner.

Built with **Next.js (App Router) · TypeScript · Tailwind CSS · wagmi · viem**.

---

## Product flow

1. A bounty owner **creates a bounty** with a title, rubric, deadline, and reward.
2. Participants **submit answers** before the deadline.
3. After the deadline, the owner clicks **Judge All Submissions**.
4. The frontend gathers all submissions, builds one Ritual LLM request, encodes
   it as `llmInput`, and calls `judgeAll(bountyId, llmInput)`.
5. The contract stores/emits the **AI review**.
6. The owner reads the AI review and clicks **Finalize Winner** with the chosen
   `winnerIndex`.
7. The contract pays the winner.

> AI review is advisory. The bounty owner finalizes the winner. All submissions
> are judged together after the deadline. Only one winner receives the reward.

---

## Configure

Copy the example env file and fill in your deployment:

```bash
cp .env.example .env.local
```

| Variable | Purpose |
| --- | --- |
| `NEXT_PUBLIC_CONTRACT_ADDRESS` | Deployed `SimpleAIBountyJudge` address. The UI shows a banner until this is set. |
| `NEXT_PUBLIC_RITUAL_RPC_URL` | Ritual Chain JSON-RPC endpoint. |
| `NEXT_PUBLIC_RITUAL_CHAIN_ID` | Numeric chain id (default `1979`). |
| `NEXT_PUBLIC_RITUAL_EXECUTOR_ADDRESS` | LLM executor / precompile-callback address used when encoding `judgeAll` input. Defaults to the LLM precompile `0x…0802`. |
| `NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID` | *(optional)* Enables the WalletConnect connector. Injected/MetaMask work without it. |

All values are read in `src/config/contract.ts` and `src/config/wagmi.ts`.

---

## Run

```bash
pnpm install      # or npm install
pnpm dev          # http://localhost:3000
```

Build / start:

```bash
pnpm build
pnpm start
```

---

## How it's wired

```
src/
  abi/AIJudge.ts            Contract ABI (provided)
  config/
    contract.ts            Address + executor + chain id from env vars
    wagmi.ts               Custom Ritual Chain + wagmi config
  app/
    providers.tsx          'use client' wagmi + React Query provider tree
    layout.tsx             Server layout (fonts, metadata) -> Providers
    page.tsx               Dashboard: create, load-by-id, recent list, bounty view
  hooks/
    useBounty.ts           Reads + parses getBounty (polls so status updates)
    useWriteTx.ts          idle -> wallet -> pending -> confirmed | failed tx state
    useRecentBounties.ts   localStorage list of created/opened bounty ids
  lib/
    ritualLlm.ts           buildJudgeAllLlmInput() — Ritual LLM request encoder
    aiReview.ts            Decode aiReview bytes + parse judge JSON
    bounty.ts              Bounty type, status logic, submission gating
    format.ts              Address/amount/timestamp formatting helpers
  components/               UI primitives + each feature card
```

### The Ritual LLM encoder (`src/lib/ritualLlm.ts`)

`buildJudgeAllLlmInput({ executorAddress, title, rubric, submissions })` builds
the batch-judging prompt (using the workshop's exact template, low temperature
for stable judging) and ABI-encodes it with viem's `encodeAbiParameters` into
the `bytes` passed to `judgeAll`.

> ⚠️ **The exact Ritual LLM precompile ABI is not yet publicly pinned down.**
> The encoder uses a clearly-documented *best-effort* tuple layout and is kept
> isolated so only this file needs to change when the real ABI is published.
> Flip the `ENCODING` constant to `"json"` for a mocked UTF-8 JSON payload that
> lets the full create -> submit -> judge -> finalize flow run end-to-end against
> a contract that simply stores/echoes the bytes.

### AI review display

After `judgeAll`, the UI reads `aiReview` from `getBounty`, decodes the bytes to
text, and tries to parse the judge JSON (`winnerIndex`, `ranking`, `summary`).
It renders the recommended winner, a ranking table with scores and reasons, and
the summary. If parsing fails, it shows the raw response in a code block. The
finalize input is prefilled with the AI's recommended `winnerIndex`.

---

## Notes for the workshop

- Transaction buttons show clear states and disable while pending.
- Owner-only actions (Judge / Finalize) only appear for the connected owner.
- The "recent bounties" list is kept in `localStorage` (no indexer required).
- Multicall is **not** assumed — submissions are read one-by-one, so it works on
  a fresh chain without a deployed multicall contract.
