// Port of Selection.swift. Used by the dryrun CLI only; the server never re-selects a run.
import { hasDeparted, normalizeCode, parseEpoch } from './state.js';
import type { Station, Train } from './types.js';

export interface Selection {
  train: Train;
  station: Station;
}

function dayKey(epochSec: number, tz: string): string {
  return new Intl.DateTimeFormat('en-CA', { timeZone: tz, year: 'numeric', month: '2-digit', day: '2-digit' }).format(
    new Date(epochSec * 1000),
  );
}

export function startsToday(t: Train, nowMs: number): boolean {
  const origin = t.stations?.[0];
  if (!origin) return false;
  const dep = parseEpoch(origin.schDep) ?? parseEpoch(origin.schArr);
  if (dep == null) return false;
  const tz = origin.tz || t.originTZ || 'UTC';
  try {
    return dayKey(dep, tz) === dayKey(nowMs / 1000, tz);
  } catch {
    return false;
  }
}

const schedKey = (s: Station) => parseEpoch(s.schArr) ?? parseEpoch(s.schDep);

export function selectRun(runs: Train[], stationCode: string, nowMs: number): Selection | null {
  const code = normalizeCode(stationCode);
  const candidates: Selection[] = [];
  for (const t of runs) {
    const st = t.stations?.find((s) => normalizeCode(s.code) === code);
    if (st) candidates.push({ train: t, station: st });
  }
  if (candidates.length === 0) return null;
  const key = (s: Selection, d: number) => schedKey(s.station) ?? d;
  const minBy = (xs: Selection[], d: number) => xs.reduce((a, b) => (key(b, d) < key(a, d) ? b : a));
  const todays = candidates.filter((c) => startsToday(c.train, nowMs));
  if (todays.length) return minBy(todays, Infinity);
  const upcoming = candidates.filter((c) => !hasDeparted(c.station));
  if (upcoming.length) return minBy(upcoming, Infinity);
  return candidates.reduce((a, b) => (key(b, -Infinity) > key(a, -Infinity) ? b : a));
}
