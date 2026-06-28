"use client";

import { useState } from "react";
import { useAccount } from "wagmi";
import { useNow } from "@/hooks/useNow";
import aiJudgeAbi from "@/abi/AIJudge";
import { contractAddress } from "@/config/contract";
import { ritualChain } from "@/config/wagmi";
import { canSubmit, type Bounty } from "@/lib/bounty";
import { useWriteTx } from "@/hooks/useWriteTx";
import {
  Card,
  CardHeader,
  CardBody,
  Field,
  Textarea,
  Button,
  TxStatus,
} from "@/components/ui";

const explorerBase = ritualChain.blockExplorers?.default.url;

export function SubmitAnswer({
  bountyId,
  bounty,
  onSubmitted,
}: {
  bountyId: bigint;
  bounty: Bounty;
  onSubmitted: () => void;
}) {
  const { isConnected } = useAccount();
  const [answer, setAnswer] = useState("");
  const now = useNow();
  const tx = useWriteTx(() => {
    setAnswer("");
    onSubmitted();
  });

  // Submission window closed — nothing to show.
  if (!canSubmit(bounty, now / 1000)) return null;

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    if (!answer.trim() || !contractAddress) return;
    try {
      await tx.run({
        address: contractAddress,
        abi: aiJudgeAbi,
        functionName: "submitAnswer",
        args: [bountyId, answer.trim()],
        chainId: ritualChain.id,
      });
    } catch {
      /* surfaced via tx.state */
    }
  }

  return (
    <Card>
      <CardHeader
        title="Submit an answer"
        subtitle="Open until the deadline. One entry, judged against the rubric."
      />
      <CardBody>
        <form onSubmit={handleSubmit} className="space-y-3">
          <Field label="Your answer">
            <Textarea
              value={answer}
              onChange={(e) => setAnswer(e.target.value)}
              rows={5}
              placeholder="Write your submission…"
            />
          </Field>
          <Button
            type="submit"
            disabled={!isConnected || !answer.trim() || tx.isBusy}
            className="w-full"
          >
            {tx.isBusy ? "Submitting…" : "Submit answer"}
          </Button>
          {!isConnected && (
            <p className="text-xs text-zinc-500">
              Connect your wallet to submit.
            </p>
          )}
          <TxStatus
            state={tx.state}
            error={tx.error}
            hash={tx.hash}
            explorerBase={explorerBase}
          />
        </form>
      </CardBody>
    </Card>
  );
}
