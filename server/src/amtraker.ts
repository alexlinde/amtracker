import type { Train } from './types.js';

export const AMTRAKER_BASE = 'https://api-v3.amtraker.com/v3/trains';

export type TrainFetcher = (trainNum: string) => Promise<Train[]>;

/** GET /v3/trains/{num} -> runs. Throws on network/HTTP/parse failure; returns [] if the number has no runs. */
export const fetchRuns: TrainFetcher = async (trainNum) => {
  const res = await fetch(`${AMTRAKER_BASE}/${encodeURIComponent(trainNum)}`, {
    signal: AbortSignal.timeout(10_000),
    headers: { accept: 'application/json' },
  });
  if (!res.ok) throw new Error(`amtraker HTTP ${res.status}`);
  const body = (await res.json()) as Record<string, Train[]> | null;
  if (!body || typeof body !== 'object') return [];
  const runs = body[trainNum] ?? Object.values(body)[0];
  return Array.isArray(runs) ? runs : [];
};

/** Find the locked run by trainID. */
export function findRun(runs: Train[], trainID: string): Train | null {
  return runs.find((t) => t.trainID === trainID) ?? null;
}
