import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { test } from 'node:test';
import { apnsHeaders, apnsHost, buildPayload, choosePriority, isDeadToken, signJwt } from './apns.js';
import { run } from './helpers.test-util.js';
import { computeContentState } from './state.js';

const KEYS = [
  'phase', 'statusLabel', 'statusColor', 'etaEpoch', 'scheduledEpoch', 'delayMinutes',
  'nextStopName', 'stopsAway', 'lat', 'lon', 'speedMph', 'updatedEpoch',
];

test('update payload shape matches contract', () => {
  const state = computeContentState(run('6-19'), 'TRU')!;
  const body = JSON.parse(JSON.stringify(buildPayload(state, 1763575000.9, 'update')));
  assert.deepEqual(Object.keys(body), ['aps']);
  const aps = body.aps;
  assert.equal(aps.timestamp, 1763575000);
  assert.equal(aps.event, 'update');
  assert.equal(aps['stale-date'], 1763575000 + 900);
  assert.equal('dismissal-date' in aps, false);
  const cs = aps['content-state'];
  assert.deepEqual(Object.keys(cs).sort(), [...KEYS].sort());
  for (const k of ['etaEpoch', 'scheduledEpoch', 'updatedEpoch', 'delayMinutes', 'stopsAway', 'lat', 'lon', 'speedMph']) {
    assert.equal(typeof cs[k], 'number', k);
  }
  for (const k of ['phase', 'statusLabel', 'statusColor', 'nextStopName']) assert.equal(typeof cs[k], 'string', k);
  assert.ok(Number.isInteger(cs.etaEpoch) && cs.etaEpoch > 1.7e9 && cs.etaEpoch < 1e11, 'epoch seconds, not ms');
});

test('end payload has dismissal-date = timestamp + 15 min', () => {
  const state = computeContentState(run('6-19'), 'TRU')!;
  const aps = buildPayload(state, 1763575000, 'end').aps;
  assert.equal(aps.event, 'end');
  assert.equal(aps['dismissal-date'], 1763575000 + 900);
});

test('headers and hosts', () => {
  assert.equal(apnsHost('development'), 'api.sandbox.push.apple.com');
  assert.equal(apnsHost('production'), 'api.push.apple.com');
  assert.deepEqual(apnsHeaders('com.somefamilies.amtracker', 5, 'JWT'), {
    'apns-push-type': 'liveactivity',
    'apns-topic': 'com.somefamilies.amtracker.push-type.liveactivity',
    'apns-priority': '5',
    authorization: 'bearer JWT',
  });
});

test('priority: 10 on label/phase change or >=5 min delay change', () => {
  const a = computeContentState(run('6-19'), 'TRU')!;
  assert.equal(choosePriority(a, { ...a, lat: 1 }), 5);
  assert.equal(choosePriority(a, { ...a, delayMinutes: a.delayMinutes + 4 }), 5);
  assert.equal(choosePriority(a, { ...a, delayMinutes: a.delayMinutes + 5 }), 10);
  assert.equal(choosePriority(a, { ...a, statusLabel: 'On Time' }), 10);
  assert.equal(choosePriority(a, { ...a, phase: 'atStation' }), 10);
  assert.equal(choosePriority(null, a), 10);
});

test('dead token detection', () => {
  assert.equal(isDeadToken({ status: 410 }), true);
  assert.equal(isDeadToken({ status: 400, reason: 'BadDeviceToken' }), true);
  assert.equal(isDeadToken({ status: 400, reason: 'ExpiredToken' }), true);
  assert.equal(isDeadToken({ status: 400, reason: 'BadTopic' }), false);
  assert.equal(isDeadToken({ status: 429 }), false);
});

test('JWT is ES256 with kid/iss/iat and a verifiable ieee-p1363 signature', () => {
  const { privateKey, publicKey } = crypto.generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
  const pem = privateKey.export({ type: 'pkcs8', format: 'pem' }) as string;
  const jwt = signJwt(pem, 'KEYID12345', 'TEAMID1234', 1763575000);
  const [h, c, s] = jwt.split('.') as [string, string, string];
  assert.deepEqual(JSON.parse(Buffer.from(h, 'base64url').toString()), { alg: 'ES256', kid: 'KEYID12345' });
  assert.deepEqual(JSON.parse(Buffer.from(c, 'base64url').toString()), { iss: 'TEAMID1234', iat: 1763575000 });
  const sig = Buffer.from(s, 'base64url');
  assert.equal(sig.length, 64);
  assert.equal(
    crypto.verify('sha256', Buffer.from(`${h}.${c}`), { key: publicKey, dsaEncoding: 'ieee-p1363' }, sig),
    true,
  );
  assert.ok(!/[+/=]/.test(jwt), 'base64url without padding');
});
