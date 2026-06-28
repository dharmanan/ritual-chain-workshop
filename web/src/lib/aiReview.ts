import { hexToString } from "viem";

export type RankingEntry = {
  index: number;
  score: number;
  reason: string;
};

export type JudgeResult = {
  winnerIndex: number;
  ranking: RankingEntry[];
  summary: string;
};

export type DecodedAiReview = {
  /** Raw decoded text (UTF-8 best-effort) of the on-chain `aiReview` bytes. */
  raw: string;
  /** Parsed judge result, or null if the bytes weren't parseable JSON. */
  parsed: JudgeResult | null;
};

const EMPTY_BYTES = new Set(["", "0x"]);

/**
 * Decode the on-chain `aiReview` bytes into text and, when possible, a parsed
 * judge result.
 *
 * The contract stores the model's response bytes. We try to read them as UTF-8,
 * strip any stray markdown fences, pull out the first JSON object, and parse it
 * into the `{ winnerIndex, ranking, summary }` shape. If anything fails we still
 * return the raw text so the UI can show it verbatim.
 */
export function decodeAiReview(aiReviewHex?: string): DecodedAiReview | null {
  if (!aiReviewHex || EMPTY_BYTES.has(aiReviewHex)) return null;

  let raw: string;
  try {
    raw = hexToString(aiReviewHex as `0x${string}`);
  } catch {
    // Not valid UTF-8 bytes — surface the hex itself.
    raw = aiReviewHex;
  }

  const parsed = tryParseJudgeResult(raw);
  return { raw, parsed };
}

function tryParseJudgeResult(text: string): JudgeResult | null {
  const candidate = extractJson(text);
  if (!candidate) return null;

  let obj: unknown;
  try {
    obj = JSON.parse(candidate);
  } catch {
    return null;
  }

  if (!obj || typeof obj !== "object") return null;
  const o = obj as Record<string, unknown>;

  if (typeof o.winnerIndex !== "number") return null;

  const ranking: RankingEntry[] = Array.isArray(o.ranking)
    ? (o.ranking as unknown[])
        .map((r) => {
          if (!r || typeof r !== "object") return null;
          const e = r as Record<string, unknown>;
          return {
            index: typeof e.index === "number" ? e.index : Number(e.index),
            score: typeof e.score === "number" ? e.score : Number(e.score),
            reason: typeof e.reason === "string" ? e.reason : String(e.reason ?? ""),
          } satisfies RankingEntry;
        })
        .filter((r): r is RankingEntry => r !== null)
    : [];

  return {
    winnerIndex: o.winnerIndex,
    ranking,
    summary: typeof o.summary === "string" ? o.summary : "",
  };
}

/** Strip markdown fences and isolate the first {...} block. */
function extractJson(text: string): string | null {
  let t = text.trim();
  // Remove ```json ... ``` fences if present.
  const fence = t.match(/```(?:json)?\s*([\s\S]*?)```/i);
  if (fence) t = fence[1].trim();

  const start = t.indexOf("{");
  const end = t.lastIndexOf("}");
  if (start === -1 || end === -1 || end <= start) return null;
  return t.slice(start, end + 1);
}
