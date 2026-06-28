"use client";

import { useEffect, useState } from "react";

/**
 * Current wall-clock time (ms), refreshed on an interval. Lets render stay pure
 * — components read `now` from state instead of calling `Date.now()` during
 * render — while time-based gates (deadline passed?) still update live.
 *
 * Starts at 0 so the server and first client render agree (no hydration
 * mismatch); the real time lands immediately after mount.
 */
export function useNow(intervalMs = 15_000): number {
  const [now, setNow] = useState(0);

  useEffect(() => {
    const tick = () => setNow(Date.now());
    tick();
    const id = setInterval(tick, intervalMs);
    return () => clearInterval(id);
  }, [intervalMs]);

  return now;
}
