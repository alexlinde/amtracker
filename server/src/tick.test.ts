import assert from 'node:assert/strict';
import { test } from 'node:test';
import type { ApnsRequest, ApnsResult, ApnsSender } from './apns.js';
import { fixtureRuns, run } from './helpers.test-util.js';
import { makeHandler, safeEqual, validateTripBody } from './index.js';
import { MemoryStore } from './store.js';
import { HEARTBEAT_MS, pushNow, runTick, type Deps } from './tick.js';
import type { Train, Trip } from './types.js';

class FakeApns implements ApnsSender {
  sent: ApnsRequest[] = [];
  next: ApnsResult = { status: 200 };
  async send(r: ApnsRequest) {
    this.sent.push(r);
    return this.next;
  }
}

function setup(runs: () => Train[] | Error = () => fixtureRuns()) {
  const clock = { t: Date.parse('2026-11-19T18:30:00Z') };
  const fetches: string[] = [];
  const apns = new FakeApns();
  const store = new MemoryStore();
  const deps: Deps = {
    store,
    apns,
    now: () => clock.t,
    fetchRuns: async (n) => {
      fetches.push(n);
      const r = runs();
      if (r instanceof Error) throw r;
      return r;
    },
  };
  return { clock, fetches, apns, store, deps };
}

const trip = (id: string, over: Partial<Trip> = {}, now = Date.parse('2026-11-19T18:30:00Z')): Trip => ({
  activityId: id,
  pushToken: 'ab'.repeat(32),
  apnsEnv: 'development',
  trainNum: '6',
  trainID: '6-19',
  stationCode: 'TRU',
  createdAt: now,
  lastPushAt: 0,
  lastStateHash: '',
  lastState: null,
  ...over,
});

test('first tick pushes; unchanged tick does not; heartbeat after 15 min; change pushes', async () => {
  const s = setup();
  await s.store.put(trip('a'));
  let r = await runTick(s.deps);
  assert.deepEqual(r, { trips: 1, pushed: 1, ended: 0 });
  assert.equal(s.apns.sent.length, 1);
  assert.equal(s.apns.sent[0]!.body.aps.event, 'update');
  assert.equal(s.apns.sent[0]!.priority, 10);

  s.clock.t += 60_000;
  r = await runTick(s.deps);
  assert.equal(r.pushed, 0);
  assert.equal(s.apns.sent.length, 1);

  s.clock.t += HEARTBEAT_MS;
  r = await runTick(s.deps);
  assert.equal(r.pushed, 1);
  assert.equal(s.apns.sent[0]!.body.aps['content-state'].delayMinutes, s.apns.sent[1]!.body.aps['content-state'].delayMinutes);

  // data change: delay grows by 6 -> priority 10
  const runs = fixtureRuns();
  runs.find((t) => t.trainID === '6-19')!.stations!.find((x) => x.code === 'TRU')!.arr = '2026-11-19T14:33:00-08:00';
  const s2 = setup(() => runs);
  await s2.store.put(trip('a'));
  await runTick(s2.deps);
  const stored = (await s2.store.get('a'))!;
  assert.ok(stored.lastStateHash && stored.lastState && stored.lastPushAt === s2.clock.t);
  s2.deps.fetchRuns = async () => {
    const x = fixtureRuns();
    x.find((t) => t.trainID === '6-19')!.stations!.find((st) => st.code === 'TRU')!.arr = '2026-11-19T14:39:00-08:00';
    return x;
  };
  s2.clock.t += 60_000;
  assert.equal((await runTick(s2.deps)).pushed, 1);
  assert.equal(s2.apns.sent[1]!.priority, 10);
});

test('dedupes fetches per trainNum within a tick', async () => {
  const s = setup();
  await s.store.put(trip('a'));
  await s.store.put(trip('b'));
  await s.store.put(trip('c', { trainNum: '5', trainID: '5-1' }));
  await runTick(s.deps);
  assert.deepEqual([...s.fetches].sort(), ['5', '6']);
});

test('fetch failure skips the trip without ending it', async () => {
  const s = setup(() => new Error('boom'));
  await s.store.put(trip('a'));
  const r = await runTick(s.deps);
  assert.deepEqual(r, { trips: 1, pushed: 0, ended: 0 });
  assert.equal(s.apns.sent.length, 0);
  assert.equal(await s.store.count(), 1);
});

test('missing run ends the trip only after 3 consecutive misses; a reappearance resets', async () => {
  const s = setup();
  await s.store.put(trip('a'));
  await runTick(s.deps);
  const present = s.deps.fetchRuns;
  const missing = async () => fixtureRuns().filter((t) => t.trainID !== '6-19');
  s.deps.fetchRuns = missing;
  s.clock.t += 60_000;
  assert.deepEqual(await runTick(s.deps), { trips: 1, pushed: 0, ended: 0 });
  s.deps.fetchRuns = present; // transient blip: run is back
  s.clock.t += 60_000;
  await runTick(s.deps);
  assert.equal((await s.store.get('a'))!.missCount ?? 0, 0);
  s.deps.fetchRuns = missing;
  for (let i = 0; i < 2; i++) {
    s.clock.t += 60_000;
    assert.deepEqual(await runTick(s.deps), { trips: 1, pushed: 0, ended: 0 });
  }
  s.clock.t += 60_000;
  const r = await runTick(s.deps);
  assert.deepEqual(r, { trips: 1, pushed: 0, ended: 1 });
  const last = s.apns.sent.at(-1)!;
  assert.equal(last.body.aps.event, 'end');
  assert.equal(last.body.aps['dismissal-date'], Math.floor(s.clock.t / 1000) + 900);
  assert.equal(await s.store.count(), 0);
});

test('departed + 10 min ends; before that it keeps updating', async () => {
  const mk = (depMs: number) => () => {
    const r = fixtureRuns();
    const tru = r.find((t) => t.trainID === '6-19')!.stations!.find((x) => x.code === 'TRU')!;
    tru.status = 'Departed';
    tru.dep = new Date(depMs).toISOString();
    return r;
  };
  const s = setup();
  const depMs = s.clock.t - 5 * 60_000;
  s.deps.fetchRuns = async () => mk(depMs)();
  await s.store.put(trip('a'));
  let r = await runTick(s.deps);
  assert.deepEqual(r, { trips: 1, pushed: 1, ended: 0 });
  assert.equal(s.apns.sent[0]!.body.aps['content-state'].phase, 'departed');
  s.clock.t += 5 * 60_000;
  r = await runTick(s.deps);
  assert.deepEqual(r, { trips: 1, pushed: 0, ended: 1 });
  assert.equal(s.apns.sent[1]!.body.aps.event, 'end');
  assert.equal(await s.store.count(), 0);
});

test('trip older than 12h ends', async () => {
  const s = setup();
  await s.store.put(trip('a', { createdAt: s.clock.t - 12 * 3600_000 - 1 }));
  const r = await runTick(s.deps);
  assert.equal(r.ended, 1);
  assert.equal(s.apns.sent[0]!.body.aps.event, 'end');
});

test('410 and BadDeviceToken delete the trip; other errors keep it', async () => {
  for (const res of [{ status: 410 }, { status: 400, reason: 'BadDeviceToken' }, { status: 400, reason: 'ExpiredToken' }]) {
    const s = setup();
    s.apns.next = res;
    await s.store.put(trip('a'));
    const r = await runTick(s.deps);
    assert.equal(r.pushed, 0);
    assert.equal(await s.store.count(), 0, JSON.stringify(res));
  }
  const s = setup();
  s.apns.next = { status: 503, reason: 'ServiceUnavailable' };
  await s.store.put(trip('a'));
  await runTick(s.deps);
  const t = (await s.store.get('a'))!;
  assert.equal(t.lastPushAt, 0, 'not marked pushed; retried next tick');
});

test('pushNow forces a send even when state unchanged', async () => {
  const s = setup();
  await s.store.put(trip('a'));
  await runTick(s.deps);
  const t = (await s.store.get('a'))!;
  await pushNow(t, s.deps);
  assert.equal(s.apns.sent.length, 2);
});

// ---- HTTP layer ----
test('http: auth, validation, upsert + immediate push, delete, tick', async () => {
  const s = setup();
  const server = (await import('node:http')).createServer(makeHandler(s.deps, { appSecret: 'app-s', tickSecret: 'tick-s' }));
  await new Promise<void>((r) => server.listen(0, r));
  const base = `http://127.0.0.1:${(server.address() as { port: number }).port}`;
  const body = { activityId: 'act-1', pushToken: 'cd'.repeat(32), apnsEnv: 'development', trainNum: '6', trainID: '6-19', stationCode: 'tru' };
  const post = (path: string, auth: Record<string, string>, b?: unknown) =>
    fetch(base + path, { method: 'POST', headers: { 'content-type': 'application/json', ...auth }, body: b === undefined ? undefined : JSON.stringify(b) });
  try {
    assert.equal((await fetch(base + '/health')).status, 200);
    assert.equal((await post('/trips', {}, body)).status, 401);
    assert.equal((await post('/trips', { authorization: 'Bearer wrong' }, body)).status, 401);
    assert.equal((await post('/trips', { authorization: 'Bearer app-s' }, { ...body, apnsEnv: 'x' })).status, 400);
    const ok = await post('/trips', { authorization: 'Bearer app-s' }, body);
    assert.equal(ok.status, 200);
    assert.deepEqual(await ok.json(), { ok: true });
    assert.equal(s.apns.sent.length, 1);
    assert.equal((await s.store.get('act-1'))!.stationCode, 'TRU');
    assert.equal((await post('/tick', { 'x-tick-secret': 'nope' })).status, 401);
    const tick = await post('/tick', { 'x-tick-secret': 'tick-s' });
    assert.deepEqual(await tick.json(), { trips: 1, pushed: 0, ended: 0 });
    const del = await fetch(base + '/trips/act-1', { method: 'DELETE', headers: { authorization: 'Bearer app-s' } });
    assert.equal(del.status, 200);
    assert.equal(await s.store.count(), 0);
    assert.equal((await fetch(base + '/trips/act-1', { method: 'DELETE', headers: { authorization: 'Bearer app-s' } })).status, 200);
  } finally {
    server.close();
  }
});

test('safeEqual / validateTripBody', () => {
  assert.equal(safeEqual('abc', 'abc'), true);
  assert.equal(safeEqual('abc', 'abd'), false);
  assert.equal(safeEqual('abc', 'abcd'), false);
  assert.equal(typeof validateTripBody({}), 'string');
  assert.equal(typeof validateTripBody({ activityId: '../x', pushToken: 'ab'.repeat(16), apnsEnv: 'production', trainNum: '6', trainID: '6-1', stationCode: 'TRU' }), 'string');
});
