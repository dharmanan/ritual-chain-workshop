# Privacy-Preserving AI Bounty Judge (Commit-Reveal)

Ritual Academy assignment, Required Track: commit-reveal bounty contract.

This is an upgrade of the starter `AIJudge.sol`. The starter stores every answer
as plaintext the moment it is submitted (`submitAnswer`), so anyone watching
the chain can read a rival's answer and submit a slightly better copy before the
deadline. `CommitRevealBountyJudge` fixes that by keeping answers secret during
the contest via a commit-reveal scheme. Answers are only judged by the Ritual LLM
inference precompile once every entry is locked in.

```
create -> [commit window] -> [reveal window] -> judge -> finalize
```

## Files

| Path | What it is |
|------|------------|
| `contracts/CommitRevealBountyJudge.sol` | The contract (this deliverable). |
| `contracts/utils/PrecompileConsumer.sol` | Ritual precompile helper (unchanged from starter). |
| `contracts/CommitRevealBountyJudge.t.sol` | Foundry-style Solidity unit tests (mocked precompile). |
| `ignition/modules/CommitRevealBountyJudge.ts` | Ignition deployment module. |
| `TEST_PLAN.md` | Full test matrix. |
| `ARCHITECTURE.md` | Design, data-flow, and commit-reveal vs Ritual-native comparison. |
| `ADVANCED_TRACK.md` | Advanced-track design: TEE-based hidden submissions and flow diagram. |
| `REFLECTION.md` | Reflection answer. |

Drop the `contracts/` and `ignition/` files into the workshop's `hardhat/`
project. They reuse the existing `utils/PrecompileConsumer.sol`.

## The four required functions

| Function | Phase | Who | Notes |
|----------|-------|-----|-------|
| `submitCommitment(uint256 bountyId, bytes32 commitment)` | commit | entrant | Stores only a hash. The answer stays hidden. |
| `revealAnswer(uint256 bountyId, string answer, bytes32 salt)` | reveal | entrant | Verifies the hash, then records the plaintext answer. |
| `judgeAll(uint256 bountyId, bytes llmInput)` | judge | owner | Calls `LLM_INFERENCE_PRECOMPILE` (`0x0802`) over the revealed answers. |
| `finalizeWinner(uint256 bountyId, uint256 winnerIndex)` | finalize | owner | Pays the reward to the winning author. |

Supporting functions: `createBounty`, `cancelBounty` (refund if nobody revealed),
`assembleAnswers`, `getBountyInfo`, `getBountyState`, `getSubmission`,
`getCommitment`, `computeCommitment`.

## The commitment formula

```
commitment = keccak256(abi.encodePacked(answer, salt, msg.sender, bountyId))
```

This is the formula specified in the homework brief. Including `salt` prevents
brute-forcing of short answers. Including `msg.sender` prevents a copycat from
taking a revealed pair out of the mempool and claiming someone else's answer as
their own. Including `bountyId` prevents the same commitment from being replayed
across a different bounty. `encodePacked` is safe here because the only dynamic
field (`answer`) comes first, followed by three fixed-size fields, so no hash
collision is possible.

### Computing it in the front end (viem)

```ts
import { keccak256, encodePacked, toHex } from "viem";

const salt = toHex(crypto.getRandomValues(new Uint8Array(32)));
const commitment = keccak256(
  encodePacked(
    ["string", "bytes32", "address", "uint256"],
    [answer, salt, committer, bountyId],
  ),
);
// submitCommitment(bountyId, commitment)  ... later ...  revealAnswer(bountyId, answer, salt)
```

> Users must keep `answer` and `salt` until the reveal window. If either is
> lost, the answer can never be revealed and the reward becomes unreachable.

## Setup, build, test

```shell
cd hardhat
pnpm install
npx hardhat compile
npx hardhat test solidity
```

## Deploy to Ritual

The workshop config already defines a `ritual` network (chainId `1979`,
`https://rpc.ritualfoundation.org`). Set the deployer key, then:

```shell
export DEPLOYER_PRIVATE_KEY=your_key_here
npx hardhat ignition deploy --network ritual ignition/modules/CommitRevealBountyJudge.ts
```

## Worked example

1. **Create** - owner calls `createBounty("Best haiku", "5-7-5, most evocative", commitDL, revealDL)` with the reward as value.
2. **Commit** - each entrant computes the hash locally and calls `submitCommitment`.
3. **Reveal** - after `commitDeadline`, entrants call `revealAnswer(id, answer, salt)`.
4. **Judge** - after `revealDeadline`, owner builds `llmInput` from the rubric and `assembleAnswers(id)`, then calls `judgeAll`. The raw LLM verdict is stored in `aiReview`.
5. **Finalize** - owner reads the verdict, calls `finalizeWinner(id, winnerIndex)`, and the reward transfers to that author.

If no one reveals before `revealDeadline`, the owner calls `cancelBounty(id)` to
reclaim the reward.
