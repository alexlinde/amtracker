import assert from 'node:assert/strict';
import { test } from 'node:test';
import { fixtureRuns, run } from './helpers.test-util.js';
import { selectRun } from './selection.js';
import { MAX_TRIP_AGE_MS, computeContentState, decideEnd, roundHalfAway } from './state.js';

const t = (s: string) => Date.parse(s) / 1000;

test('fixture: 6-19 to Truckee is enroute, 26 min late, 4 stops away', () => {
  const s = computeContentState(run('6-19'), 'TRU')!;
  assert.deepEqual(s, {
    phase: 'enroute',
    statusLabel: 'Delayed',
    statusColor: 'orange',
    etaEpoch: t('2026-11-19T14:27:00-08:00'),
    scheduledEpoch: t('2026-11-19T14:01:00-08:00'),
    delayMinutes: 26,
    nextStopName: 'Davis',
    stopsAway: 4,
    lat: 38.282620681070966,
    lon: -121.97324929197292,
    speedMph: 78,
    updatedEpoch: t('2026-11-19T10:26:10-08:00'),
  });
});

test('fixture: departed run 6-17 at Truckee', () => {
  const s = computeContentState(run('6-17'), 'TRU')!;
  assert.equal(s.phase, 'departed');
  assert.equal(s.statusLabel, 'Departed');
  assert.equal(s.statusColor, 'gray');
  assert.equal(s.stopsAway, -1);
  assert.equal(s.delayMinutes, 19);
});

test('stopsAway 0 when next stop is target', () => {
  const r = run('6-19');
  const s = computeContentState(r, 'DAV')!;
  assert.equal(s.stopsAway, 0);
});

test('status thresholds: on time / early / delayed / late', () => {
  const r = run('6-19');
  const tru = r.stations!.find((x) => x.code === 'TRU')!;
  const cases: [string, string, string, string][] = [
    ['2026-11-19T14:01:00-08:00', 'On Time', 'green', '0'],
    ['2026-11-19T13:50:00-08:00', 'On Time', 'green', '-11'],
    ['2026-11-19T14:02:00-08:00', 'Delayed', 'orange', '1'],
    ['2026-11-19T14:59:00-08:00', 'Delayed', 'orange', '58'],
    ['2026-11-19T15:01:00-08:00', 'Delayed', 'red', '60'],
  ];
  for (const [arr, label, color, delay] of cases) {
    tru.arr = arr;
    const s = computeContentState(r, 'TRU')!;
    assert.equal(s.statusLabel, label, arr);
    assert.equal(s.statusColor, color, arr);
    assert.equal(s.delayMinutes, Number(delay), arr);
  }
});

test('no estimate -> Scheduled/gray, eta falls back to scheduled', () => {
  const r = run('6-19');
  const tru = r.stations!.find((x) => x.code === 'TRU')!;
  delete tru.arr;
  delete tru.dep;
  const s = computeContentState(r, 'TRU')!;
  assert.equal(s.statusLabel, 'Scheduled');
  assert.equal(s.statusColor, 'gray');
  assert.equal(s.etaEpoch, s.scheduledEpoch);
  assert.equal(s.delayMinutes, 0);
});

test('at station -> atStation / Arrived', () => {
  const r = run('6-19');
  r.stations!.find((x) => x.code === 'DAV')!.status = 'Station';
  const s = computeContentState(r, 'DAV')!;
  assert.equal(s.phase, 'atStation');
  assert.equal(s.statusLabel, 'Arrived');
});

test('origin station uses departure times', () => {
  const r = run('6-19');
  const emy = r.stations![0]!;
  emy.status = 'Enroute';
  emy.arr = '2026-11-19T08:20:00-08:00'; // arrival ignored for origin
  emy.dep = '2026-11-19T08:30:00-08:00';
  emy.schArr = '2026-11-19T08:00:00-08:00';
  emy.schDep = '2026-11-19T08:25:00-08:00';
  const s = computeContentState(r, 'EMY')!;
  assert.equal(s.scheduledEpoch, t('2026-11-19T08:25:00-08:00'));
  assert.equal(s.etaEpoch, t('2026-11-19T08:30:00-08:00'));
  assert.equal(s.delayMinutes, 5);
});

test('missing fields default sensibly; unknown phase when not active', () => {
  const r = run('6-19');
  r.trainState = '';
  delete r.lat;
  delete r.lon;
  delete r.velocity;
  delete r.eventName;
  delete r.lastValTS;
  delete r.updatedAt;
  const s = computeContentState(r, 'TRU')!;
  assert.equal(s.phase, 'unknown');
  assert.equal(s.statusColor, 'gray');
  assert.deepEqual([s.lat, s.lon, s.speedMph, s.nextStopName, s.updatedEpoch], [0, 0, 0, '', 0]);
  assert.equal(computeContentState(r, 'ZZZ'), null);
});

test('roundHalfAway matches Swift', () => {
  assert.equal(roundHalfAway(-0.5), -1);
  assert.equal(roundHalfAway(0.5), 1);
  assert.equal(roundHalfAway(25.4), 25);
});

// ---- end condition ----
const NOW = Date.parse('2026-11-19T20:00:00Z');

test('end: run missing from feed', () => {
  assert.deepEqual(decideEnd(null, 'TRU', NOW - 1000, NOW), { end: true, reason: 'missing' });
});

test('end: not finished while enroute', () => {
  assert.equal(decideEnd(run('6-19'), 'TRU', NOW - 1000, NOW).end, false);
});

test('end: departed < 10 min does not end, >= 10 min ends', () => {
  const r = run('6-19');
  const tru = r.stations!.find((x) => x.code === 'TRU')!;
  tru.status = 'Departed';
  tru.dep = new Date(NOW - 9 * 60_000).toISOString();
  assert.equal(decideEnd(r, 'TRU', NOW - 3600_000, NOW).end, false);
  tru.dep = new Date(NOW - 10 * 60_000).toISOString();
  const d = decideEnd(r, 'TRU', NOW - 3600_000, NOW);
  assert.equal(d.end, true);
  assert.equal(d.reason, 'finished');
});

test('end: terminus at Station for >= 10 min', () => {
  const r = run('6-19');
  r.stations!.forEach((s) => (s.status = 'Departed'));
  const chi = r.stations![r.stations!.length - 1]!;
  chi.status = 'Station';
  chi.arr = new Date(NOW - 11 * 60_000).toISOString();
  assert.equal(decideEnd(r, 'CHI', NOW - 3600_000, NOW).end, true);
  chi.arr = new Date(NOW - 5 * 60_000).toISOString();
  assert.equal(decideEnd(r, 'CHI', NOW - 3600_000, NOW).end, false);
  // a non-terminus "Station" status never ends the trip
  const r2 = run('6-19');
  r2.stations!.find((x) => x.code === 'DAV')!.status = 'Station';
  r2.stations!.find((x) => x.code === 'DAV')!.arr = new Date(NOW - 60 * 60_000).toISOString();
  assert.equal(decideEnd(r2, 'DAV', NOW - 3600_000, NOW).end, false);
});

test('end: finished with no feed timestamp uses first-seen time', () => {
  const r = run('6-19');
  const tru = r.stations!.find((x) => x.code === 'TRU')!;
  tru.status = 'Departed';
  delete tru.dep;
  delete tru.arr;
  const first = decideEnd(r, 'TRU', NOW - 3600_000, NOW);
  assert.equal(first.end, false);
  assert.equal(first.finishedAt, NOW);
  assert.equal(decideEnd(r, 'TRU', NOW - 3600_000, NOW + 10 * 60_000, first.finishedAt).end, true);
});

test('end: trip older than 12h', () => {
  const d = decideEnd(run('6-19'), 'TRU', NOW - MAX_TRIP_AGE_MS - 1, NOW);
  assert.deepEqual([d.end, d.reason], [true, 'expired']);
});

test('end: target station absent from run', () => {
  assert.equal(decideEnd(run('6-19'), 'ZZZ', NOW - 1000, NOW).end, true);
});

// ---- selection (dryrun only) ----
test('selection prefers run that started today in origin tz', () => {
  const runs = fixtureRuns();
  const pick = selectRun(runs, 'TRU', Date.parse('2026-11-19T18:00:00Z'))!;
  assert.equal(pick.train.trainID, '6-19');
  const pick2 = selectRun(runs, 'TRU', Date.parse('2026-11-17T18:00:00Z'))!;
  assert.equal(pick2.train.trainID, '6-17');
  assert.equal(selectRun(runs, 'ZZZ', NOW), null);
});
