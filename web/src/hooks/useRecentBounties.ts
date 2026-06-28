"use client";

import { useCallback, useSyncExternalStore } from "react";

const STORAGE_KEY = "aibj:recent-bounties";
const MAX = 20;
const EMPTY: string[] = [];

// Cache the parsed array so getSnapshot returns a stable reference until the
// underlying string actually changes (required by useSyncExternalStore).
let cache: { raw: string | null; value: string[] } = { raw: null, value: EMPTY };
const listeners = new Set<() => void>();

function readSnapshot(): string[] {
  if (typeof window === "undefined") return EMPTY;
  const raw = localStorage.getItem(STORAGE_KEY);
  if (raw === cache.raw) return cache.value;
  let value: string[] = EMPTY;
  try {
    value = raw ? (JSON.parse(raw) as string[]) : EMPTY;
  } catch {
    value = EMPTY;
  }
  cache = { raw, value };
  return value;
}

function serverSnapshot(): string[] {
  return EMPTY;
}

function subscribe(cb: () => void): () => void {
  listeners.add(cb);
  window.addEventListener("storage", cb);
  return () => {
    listeners.delete(cb);
    window.removeEventListener("storage", cb);
  };
}

function persist(next: string[]) {
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(next));
  } catch {
    /* ignore quota / private mode */
  }
  listeners.forEach((l) => l());
}

/**
 * Recently created/opened bounty ids, persisted in localStorage. Backed by
 * useSyncExternalStore so it's hydration-safe (server renders an empty list)
 * without needing a `mounted` flag.
 */
export function useRecentBounties() {
  const ids = useSyncExternalStore(subscribe, readSnapshot, serverSnapshot);

  const add = useCallback((id: string | bigint) => {
    const key = id.toString();
    const current = readSnapshot();
    if (current[0] === key) return;
    persist([key, ...current.filter((x) => x !== key)].slice(0, MAX));
  }, []);

  const remove = useCallback((id: string | bigint) => {
    const key = id.toString();
    persist(readSnapshot().filter((x) => x !== key));
  }, []);

  return { ids, add, remove };
}
