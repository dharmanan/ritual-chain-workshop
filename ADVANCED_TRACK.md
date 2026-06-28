# Advanced Track: Ritual-Native Hidden Submissions (Design)

The required commit-reveal track has one unavoidable property: answers become
public at reveal time, before the AI judges them. This document describes a
Ritual-native variant where answers stay encrypted until judging is complete,
using TEE-backed execution. Per the brief, the advanced track is presented as a
design rather than a full implementation.

## Goal

No participant can read any other participant's plaintext answer at any point
before judging. Only the trusted execution environment (TEE) ever sees the
plaintext, and only during the single batch judging pass.

## Where plaintext exists and who can read it

| Stage | Plaintext location | Who can read it |
|-------|--------------------|-----------------|
| Before submit | participant's own client | only that participant |
| Submission phase | nowhere in the clear, only ciphertext | nobody |
| Judging (`judgeAll`) | inside the TEE, transiently | only the enclave program |
| After finalize | the published revealed bundle (off-chain) | everyone |

## On-chain vs off-chain

On-chain: per-participant `ciphertextRef` and `submissionHash`, the bounty
deadlines and reward, and after judging the `revealedAnswersRef`,
`revealedAnswersHash`, the AI ranking and summary, and the finalized
`winnerIndex`.

Off-chain: the encrypted answer blobs and, after judging, the revealed plaintext
bundle (for example on IPFS or a storage ref). Large plaintext is never put in
contract storage. Only its hash is stored, making the bundle tamper-evident.

## How the LLM receives all submissions together (batch judging)

`judgeAll` triggers a single TEE workflow. The enclave fetches every ciphertext
by its on-chain ref, decrypts them with the key it holds, assembles one prompt
from the rubric and all decrypted answers, runs one LLM inference (never one call
per answer), and returns the verdict plus the revealed-bundle ref and hash back to
the contract.

## How the final reveal happens and is verified

After judging, the enclave publishes the plaintext bundle off-chain and the
contract records `revealedAnswersRef` and `revealedAnswersHash`. Anyone can fetch
the bundle, hash it, and check it equals the on-chain hash, so the revealed
answers are provably the same ones that were judged. The owner then calls
`finalizeWinner` using the AI's recommended index. The AI output is a
recommendation, not an automatic payout.

## Flow diagram

```
PARTICIPANTS                    CHAIN                        RITUAL TEE
submitEncrypted(ciphertextRef) -> store ref + submissionHash
                                  |
                      (commit deadline passes)
owner -> judgeAll(bountyId, llmInput) -----------------> fetch ciphertexts
                                                          decrypt (private)
                                                          build ONE batch prompt
                                                          ONE LLM inference
                                  <- ranking + ref + hash <- publish revealed bundle
                            store ranking, revealedAnswersRef/Hash
owner -> finalizeWinner(bountyId, winnerIndex) -> pay winner
anyone -> fetch bundle, hash, compare to revealedAnswersHash (verify integrity)
```

## Example final output shape

```json
{
  "winnerIndex": 2,
  "ranking": [{ "index": 2, "score": 94, "reason": "Best satisfies the rubric." }],
  "revealedAnswersRef": "ipfs://...",
  "revealedAnswersHash": "0x...",
  "summary": "Submission 2 is the strongest answer."
}
```

## Ritual features used

TEE-backed execution runs judging where private inputs are visible to the program
but hidden from the public chain. Encrypted inputs and secrets mean answers never
appear as plaintext on-chain. All answers are judged in one batch request. The
owner still finalizes the payout as a human-in-the-loop step.

## Minimal contract surface compared to the required track

```solidity
// Instead of revealAnswer storing plaintext, store an encrypted reference:
function submitEncrypted(uint256 bountyId, bytes32 submissionHash, string calldata ciphertextRef) external;

// judgeAll records the revealed bundle commitment returned by the TEE:
function judgeAll(uint256 bountyId, bytes calldata llmInput) external;

// finalizeWinner is unchanged: human finalizes.
function finalizeWinner(uint256 bountyId, uint256 winnerIndex) external;
```
