# Test Plan

## Strategy

The contract has two kinds of logic to cover.

The first is state-machine and access control: phase windows, ownership, and
one-shot actions. These are tested directly with `forge-std` cheatcodes
(`vm.warp`, `vm.prank`, `vm.expectRevert`).

The second is precompile integration: `judgeAll` calls the Ritual LLM precompile
at `0x0802`, which does not exist on a local EDR or Foundry chain. Two mocks are
substituted via `vm.etch`. `MockLLMOk` returns a success completion and
`MockLLMError` returns `hasError = true`. Both reproduce the real
short-running-async ABI: `abi.encode(bytes simmedInput, bytes actualOutput)`.

All cases below are in `contracts/CommitRevealBountyJudge.t.sol`. Run with:

```shell
npx hardhat test solidity
```

## Test matrix

### Happy path

| ID | Test | Asserts |
|----|------|---------|
| H1 | `test_FullFlow_CommitRevealJudgeFinalize` | Two entrants commit, reveal, owner judges, winner gets reward. `judged` flag set, `aiReview` non-empty, balance increased by reward. |

### Commit phase

| ID | Test | Expected revert |
|----|------|-----------------|
| C1 | `test_RevertWhen_CommitAfterDeadline` | commit window closed |
| C2 | `test_RevertWhen_DoubleCommit` | already committed |

### Reveal phase

| ID | Test | Expected revert |
|----|------|-----------------|
| R1 | `test_RevertWhen_RevealBeforeWindow` | reveal not open |
| R2 | `test_RevertWhen_RevealWrongSalt` | commitment mismatch |
| R3 | `test_RevertWhen_RevealWrongAnswer` | commitment mismatch |
| R4 | `test_RevertWhen_CopycatRevealsStolenPair` | no commitment (address binding works) |
| R5 | `test_RevertWhen_DoubleReveal` | already revealed |
| R6 | `test_RevertWhen_RevealAfterWindow` | reveal window closed |

### Judge phase

| ID | Test | Expected revert |
|----|------|-----------------|
| J1 | `test_RevertWhen_JudgeBeforeRevealClosed` | reveal still open |
| J2 | `test_RevertWhen_JudgeNotOwner` | not bounty owner |
| J3 | `test_RevertWhen_LLMReportsError` | model overloaded (from mock) |

### Finalize

| ID | Test | Expected revert |
|----|------|-----------------|
| F1 | `test_RevertWhen_FinalizeBeforeJudge` | not judged yet |
| F2 | `test_RevertWhen_FinalizeBadIndex` | invalid winner index |

### Cancel and refund

| ID | Test | Asserts |
|----|------|---------|
| X1 | `test_CancelRefundsWhenNoReveals` | owner reclaims full reward after `revealDeadline` when nobody revealed |

### View parity

| ID | Test | Asserts |
|----|------|---------|
| V1 | `test_ComputeCommitmentMatchesOnChain` | on-chain `computeCommitment` equals the local `keccak256(abi.encodePacked(...))` the front end uses |

## Edge cases noted but outside the unit test scope

Reentrancy on `finalizeWinner` and `cancelBounty` is mitigated by the
`nonReentrant` guard and checks-effects-interactions (reward zeroed before the
external call). A malicious-recipient reentrancy test would be a good follow-up.

Gas cost of `assembleAnswers` with `MAX_SUBMISSIONS` long answers is worth
benchmarking before raising the limits, though it is a view function with no
on-chain cost.

An integration test on a Ritual fork or devnet would validate the actual
`llmInput` request schema against the real precompile, beyond what the mocks
can cover.
