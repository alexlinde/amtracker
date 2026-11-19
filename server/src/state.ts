import type { ContentState, Station, Train } from './types.js';

export const END_GRACE_MS = 10 * 60_000;
export const MAX_TRIP_AGE_MS = 12 * 3600_000;

export function normalizeCode(s: string | undefined): string {
  return (s ?? '').trim().toUpperCase();
}

/** ISO8601 -> epoch seconds, or null. */
export function parseEpoch(s: string | undefined): number | null {
  if (!s) return null;
  const ms = Date.parse(s);
  return Number.isNaN(ms) ? null : ms / 1000;
}

/** Round half away from zero, like Swift's .rounded(). */
export function roundHalfAway(x: number): number {
  return x < 0 ? -Math.round(-x) : Math.round(x);
}

const eq = (a: string | undefined, b: string) => (a ?? '').toLowerCase() === b;
export const hasDeparted = (s: Station) => eq(s.status, 'departed');
export const isAtStation = (s: Station) => eq(s.status, 'station');

export function findStation(train: Train, code: string): { station: Station; index: number } | null {
  const c = normalizeCode(code);
  const stations = train.stations ?? [];
  const index = stations.findIndex((s) => normalizeCode(s.code) === c);
  const station = stations[index];
  return station ? { station, index } : null;
}

/** Port of DisplayBuilder.level(forDelay:). */
export function levelForDelay(m: number): 'onTime' | 'delayed' | 'late' {
  return m <= 0 ? 'onTime' : m >= 60 ? 'late' : 'delayed';
}

export function isDepartureOnly(train: Train, st: Station): boolean {
  const origin = normalizeCode(train.origCode);
  const code = normalizeCode(st.code);
  return (
    (origin !== '' && origin === code) ||
    (!st.schArr && !st.arr && !!st.schDep)
  );
}

export function computeContentState(train: Train, stationCode: string): ContentState | null {
  const found = findStation(train, stationCode);
  if (!found) return null;
  const { station: st, index } = found;
  const stations = train.stations ?? [];

  const depOnly = isDepartureOnly(train, st);
  const sched = depOnly
    ? (parseEpoch(st.schDep) ?? parseEpoch(st.schArr))
    : (parseEpoch(st.schArr) ?? parseEpoch(st.schDep));
  const est = depOnly
    ? (parseEpoch(st.dep) ?? parseEpoch(st.arr))
    : (parseEpoch(st.arr) ?? parseEpoch(st.dep));
  const shown = est ?? sched;
  let delay = 0;
  if (est != null && sched != null) delay = roundHalfAway((est - sched) / 60);

  const departed = hasDeparted(st);
  const atStation = isAtStation(st);
  const lvl = levelForDelay(delay);
  const trainState = (train.trainState ?? '').toLowerCase();
  const active = trainState === 'active';

  let phase: ContentState['phase'];
  if (departed) phase = 'departed';
  else if (atStation) phase = 'atStation';
  else if (active) phase = 'enroute';
  else if (trainState === 'predeparture') phase = 'scheduled';
  else phase = 'unknown';

  let statusLabel: string;
  let statusColor: ContentState['statusColor'];
  if (departed) {
    statusLabel = 'Departed';
    statusColor = 'gray';
  } else if (atStation) {
    statusLabel = 'Arrived';
    statusColor = 'green';
  } else if (est == null) {
    statusLabel = 'Scheduled';
    statusColor = 'gray';
  } else {
    statusLabel = lvl === 'onTime' ? 'On Time' : 'Delayed';
    statusColor = lvl === 'onTime' ? 'green' : lvl === 'late' ? 'red' : 'orange';
    if (phase === 'unknown') statusColor = 'gray';
  }

  const firstPending = stations.findIndex((s) => !hasDeparted(s));
  const stopsAway = departed || firstPending < 0 || index < firstPending ? -1 : index - firstPending;

  const upd = parseEpoch(train.lastValTS) ?? parseEpoch(train.updatedAt) ?? 0;
  return {
    phase,
    statusLabel,
    statusColor,
    etaEpoch: shown ?? 0,
    scheduledEpoch: sched ?? 0,
    delayMinutes: delay,
    nextStopName: train.eventName ?? '',
    stopsAway,
    lat: typeof train.lat === 'number' ? train.lat : 0,
    lon: typeof train.lon === 'number' ? train.lon : 0,
    speedMph: typeof train.velocity === 'number' ? Math.round(train.velocity) : 0,
    updatedEpoch: upd,
  };
}

/** Is the target finished (departed, or arrived at the terminus)? */
export function isFinished(train: Train, stationCode: string): boolean {
  const found = findStation(train, stationCode);
  if (!found) return false;
  const { station, index } = found;
  if (hasDeparted(station)) return true;
  const isTerminus = index === (train.stations?.length ?? 0) - 1;
  return isTerminus && isAtStation(station);
}

/** Epoch ms at which the finished condition began, from feed data (null if the feed has no timestamp). */
export function finishedAtFromFeed(train: Train, stationCode: string): number | null {
  const found = findStation(train, stationCode);
  if (!found) return null;
  const st = found.station;
  const s = hasDeparted(st) ? (parseEpoch(st.dep) ?? parseEpoch(st.arr)) : parseEpoch(st.arr);
  return s == null ? null : s * 1000;
}

export type EndReason = 'missing' | 'finished' | 'expired';

export interface EndDecision {
  end: boolean;
  reason?: EndReason;
  /** set when finished-without-feed-timestamp and we need to persist first-seen time */
  finishedAt?: number;
}

/**
 * Decide whether to end the trip. `train` is the locked run (null if missing from feed).
 * `createdAt` and `now` are epoch ms. `trackedFinishedAt` is a previously persisted first-seen time.
 */
export function decideEnd(
  train: Train | null,
  stationCode: string,
  createdAt: number,
  now: number,
  trackedFinishedAt?: number,
): EndDecision {
  if (!train) return { end: true, reason: 'missing' };
  if (now - createdAt > MAX_TRIP_AGE_MS) return { end: true, reason: 'expired' };
  if (!findStation(train, stationCode)) return { end: true, reason: 'missing' };
  if (!isFinished(train, stationCode)) return { end: false };
  const feedTs = finishedAtFromFeed(train, stationCode);
  const since = feedTs ?? trackedFinishedAt ?? now;
  const out: EndDecision = { end: now - since >= END_GRACE_MS, finishedAt: since };
  if (out.end) out.reason = 'finished';
  return out;
}
