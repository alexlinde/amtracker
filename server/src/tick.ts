import crypto from 'node:crypto';
import { buildPayload, choosePriority, isDeadToken, type ApnsSender } from './apns.js';
import { findRun, type TrainFetcher } from './amtraker.js';
import { computeContentState, decideEnd } from './state.js';
import type { TripStore } from './store.js';
import type { ContentState, Train, Trip } from './types.js';

export const HEARTBEAT_MS = 15 * 60_000;
export const MISSING_TICKS = 3;

export interface Deps {
  store: TripStore;
  apns: ApnsSender;
  fetchRuns: TrainFetcher;
  now: () => number;
  log?: (msg: string, extra?: Record<string, unknown>) => void;
}

export interface TickResult {
  trips: number;
  pushed: number;
  ended: number;
}

export function hashState(s: ContentState): string {
  return crypto.createHash('sha1').update(JSON.stringify(s)).digest('hex');
}

type RunsResult = Train[] | Error;

/** Process one trip against already-fetched runs. Returns what happened. */
export async function processTrip(
  trip: Trip,
  runs: RunsResult,
  deps: Deps,
  opts: { force?: boolean } = {},
): Promise<'pushed' | 'ended' | 'skipped' | 'deleted' | 'error'> {
  const { store, apns, now } = deps;
  const log = deps.log ?? (() => {});
  if (runs instanceof Error) {
    log('fetch failed; skipping trip', { activityId: trip.activityId, err: runs.message });
    return 'skipped';
  }
  const nowMs = now();
  const train = findRun(runs, trip.trainID);
  const decision = decideEnd(train, trip.stationCode, trip.createdAt, nowMs, trip.finishedAt);
  const state = train ? computeContentState(train, trip.stationCode) : null;
  let dirty = false;

  // A single empty/partial feed response shouldn't end the trip: require MISSING_TICKS in a row.
  if (decision.end && decision.reason === 'missing' && nowMs - trip.createdAt < 12 * 3600_000) {
    const missCount = (trip.missCount ?? 0) + 1;
    if (missCount < MISSING_TICKS) {
      await store.put({ ...trip, missCount });
      log('run missing from feed; waiting', { activityId: trip.activityId, missCount });
      return 'skipped';
    }
  } else if (train && trip.missCount) {
    trip = { ...trip, missCount: 0 };
    dirty = true;
  }

  if (decision.end) {
    const final = state ?? trip.lastState;
    try {
      if (final) {
        const res = await apns.send({
          pushToken: trip.pushToken,
          apnsEnv: trip.apnsEnv,
          body: buildPayload(final, nowMs / 1000, 'end'),
          priority: 10,
        });
        if (!(res.status === 200 || isDeadToken(res))) {
          log('apns end failed', { activityId: trip.activityId, status: res.status, reason: res.reason });
          // Retry next tick unless the trip is hopelessly old.
          if (nowMs - trip.createdAt < 13 * 3600_000) return 'error';
        }
      }
    } catch (e) {
      log('apns end threw', { activityId: trip.activityId, err: String(e) });
      if (nowMs - trip.createdAt < 13 * 3600_000) return 'error';
    }
    await store.delete(trip.activityId);
    log('trip ended', { activityId: trip.activityId, reason: decision.reason });
    return 'ended';
  }

  if (decision.finishedAt && decision.finishedAt !== trip.finishedAt) {
    trip = { ...trip, finishedAt: decision.finishedAt };
    dirty = true;
  }
  if (!state) {
    if (dirty) await store.put(trip);
    return 'skipped';
  }

  const hash = hashState(state);
  const due = nowMs - trip.lastPushAt >= HEARTBEAT_MS;
  if (!opts.force && hash === trip.lastStateHash && !due) {
    if (dirty) await store.put(trip);
    return 'skipped';
  }

  let res;
  try {
    res = await apns.send({
      pushToken: trip.pushToken,
      apnsEnv: trip.apnsEnv,
      body: buildPayload(state, nowMs / 1000, 'update'),
      priority: choosePriority(trip.lastState, state),
    });
  } catch (e) {
    log('apns update threw', { activityId: trip.activityId, err: String(e) });
    return 'error';
  }
  if (isDeadToken(res)) {
    await store.delete(trip.activityId);
    log('dead token; trip deleted', { activityId: trip.activityId, status: res.status, reason: res.reason });
    return 'deleted';
  }
  if (res.status !== 200) {
    log('apns update failed', { activityId: trip.activityId, status: res.status, reason: res.reason });
    return 'error';
  }
  await store.put({ ...trip, lastPushAt: nowMs, lastStateHash: hash, lastState: state });
  return 'pushed';
}

export async function fetchDeduped(
  trips: Trip[],
  fetcher: TrainFetcher,
): Promise<Map<string, RunsResult>> {
  const nums = [...new Set(trips.map((t) => t.trainNum))];
  const out = new Map<string, RunsResult>();
  await Promise.all(
    nums.map(async (n) => {
      try {
        out.set(n, await fetcher(n));
      } catch (e) {
        out.set(n, e instanceof Error ? e : new Error(String(e)));
      }
    }),
  );
  return out;
}

export async function runTick(deps: Deps): Promise<TickResult> {
  const trips = await deps.store.list();
  const runs = await fetchDeduped(trips, deps.fetchRuns);
  const result: TickResult = { trips: trips.length, pushed: 0, ended: 0 };
  await Promise.all(
    trips.map(async (t) => {
      try {
        const r = await processTrip(t, runs.get(t.trainNum)!, deps);
        if (r === 'pushed') result.pushed++;
        else if (r === 'ended') result.ended++;
      } catch (e) {
        deps.log?.('trip processing failed', { activityId: t.activityId, err: String(e) });
      }
    }),
  );
  return result;
}

/** Immediate compute-and-send for a freshly upserted trip. */
export async function pushNow(trip: Trip, deps: Deps) {
  const runs = await fetchDeduped([trip], deps.fetchRuns);
  return processTrip(trip, runs.get(trip.trainNum)!, deps, { force: true });
}
