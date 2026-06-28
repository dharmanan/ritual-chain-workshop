# Architecture Note

## Problem

The starter `AIJudge.sol` writes each answer to public storage immediately via
`submitAnswer`. On a transparent chain that leaks every entry: a latecomer reads
the leading answer, paraphrases it, and submits before the deadline. The contest
stops rewarding original work and starts rewarding whoever submits last. Answers
need to stay secret until the contest closes, then be judged fairly.

## Solution: commit-reveal, then AI judge

Two timed windows split the contest:

```
t0          commitDeadline       revealDeadline        judge       finalize
|  COMMIT window  |  REVEAL window      |  (owner)      |  (owner)
|  store hashes   |  disclose+verify    |  LLM precompile  |  pay winner
```

During the commit window, entrants post
`keccak256(abi.encodePacked(answer, salt, msg.sender, bountyId))`.
Storage holds only opaque hashes, so nothing about any answer leaks.

During the reveal window, entrants disclose their answer and salt. The contract
recomputes the hash and, on a match, appends the answer to the canonical
submissions array. Reveals are blocked before `commitDeadline`, so no one can
reveal early and give others something to copy while commits are still open.

Judging is only possible after `revealDeadline`, so the answer set is completely
frozen. The owner passes `llmInput` to the Ritual LLM inference precompile
(`0x0802`) and the raw verdict is stored in `aiReview` for transparency.

The owner then reads the verdict and pays the winning author via `finalizeWinner`.

## Where plaintext lives (on-chain vs off-chain)

During the commit window there is no plaintext anywhere on-chain, only hashes.
The plaintext answer and salt live off-chain in each entrant's own keeping. If
they lose either, they cannot reveal.

During the reveal window, plaintext answers become on-chain by design so the
judge and everyone else can read them. This is delayed disclosure, not permanent
encryption.

For judging, the LLM judges the whole field at once. The owner assembles one
prompt from the rubric and `assembleAnswers(bountyId)` and makes a single
`judgeAll` call to the `0x0802` precompile. One inference over all answers, not
one call per answer. The raw verdict is stored on-chain in `aiReview`.

## Key design decisions

1. **Hash binds `msg.sender` and `bountyId`.** Binding the address prevents a
   copycat from replaying a revealed pair from the mempool. Binding `bountyId`
   prevents replaying a commitment across a different bounty.

2. **Salt is required.** Prevents brute-forcing of short or predictable answers.

3. **`encodePacked` is safe for this ordering.** The only dynamic field (`answer`)
   comes first and is followed by three fixed-size fields (84 bytes total), so the
   tuple decodes uniquely with no collision risk.

4. **Judge is gated on `revealDeadline`.** Guarantees the full answer set is in
   before any judging starts.

5. **`assembleAnswers` view for auditability.** The owner supplies `llmInput`
   off-chain. This deterministic view renders the exact revealed answers so any
   observer can verify that the owner's prompt actually contains them.

6. **Refund path via `cancelBounty`.** If nobody reveals, the owner reclaims
   the reward after `revealDeadline`.

7. **Payout safety.** `nonReentrant` guard plus checks-effects-interactions
   (reward zeroed before the external call).

## Comparison: commit-reveal vs Ritual-native encrypted submissions

| Aspect | Commit-reveal (required track) | Ritual-native TEE (advanced track) |
|--------|-------------------------------|-------------------------------------|
| What is on-chain during contest | commitment hashes only | ciphertext or refs and hashes only |
| When plaintext becomes public | at reveal, before judging | only the bundle after judging |
| Who sees plaintext early | nobody, but everyone sees it post-reveal | only the TEE during judging |
| Trust anchor | chain and honest prompt assembly | chain and TEE attestation |
| Privacy ceiling | delayed disclosure | true confidentiality until judging |
| Cost and complexity | low, works on any EVM chain | higher, needs Ritual TEE and encryption |
| Batch judging | one `judgeAll` call over revealed answers | one TEE pass over decrypted answers |

The key trade-off is that commit-reveal is simple and portable but answers are
unavoidably public the moment they are revealed. The TEE design keeps answers
confidential through judging at the cost of more infrastructure and a trust
assumption on the enclave. See `ADVANCED_TRACK.md` for the full design.

## Trust model

| Actor | Trusted for | Mitigation |
|-------|-------------|------------|
| Entrant | Keeping their own salt | Their problem if lost; does not affect others. |
| Bounty owner | Building an honest `llmInput` and picking `winnerIndex` consistently with the verdict | `aiReview` stored on-chain and `assembleAnswers` view make deviations publicly visible. |
| Ritual LLM precompile | Honest judging | Relies on Ritual's coprocessor guarantees, outside this contract's scope. |
