import crypto from 'node:crypto';
import http from 'node:http';
import { HttpApnsSender } from './apns.js';
import { fetchRuns } from './amtraker.js';
import { FirestoreStore } from './store.js';
import { pushNow, runTick, type Deps } from './tick.js';
import type { ApnsEnv, Trip } from './types.js';

export function safeEqual(a: string, b: string): boolean {
  const ha = crypto.createHash('sha256').update(a).digest();
  const hb = crypto.createHash('sha256').update(b).digest();
  return crypto.timingSafeEqual(ha, hb) && a.length === b.length;
}

function log(msg: string, extra: Record<string, unknown> = {}) {
  console.log(JSON.stringify({ severity: 'INFO', message: msg, ...extra }));
}

function need(name: string): string {
  const v = process.env[name];
  if (!v) throw new Error(`missing env ${name}`);
  return v;
}

export interface Secrets {
  appSecret: string;
  tickSecret: string;
}

export function validateTripBody(b: unknown): Trip | string {
  if (!b || typeof b !== 'object') return 'body must be an object';
  const o = b as Record<string, unknown>;
  for (const k of ['activityId', 'pushToken', 'apnsEnv', 'trainNum', 'trainID', 'stationCode']) {
    if (typeof o[k] !== 'string' || !(o[k] as string).trim()) return `missing ${k}`;
  }
  const activityId = (o.activityId as string).trim();
  if (!/^[A-Za-z0-9_-]{1,128}$/.test(activityId)) return 'bad activityId';
  const pushToken = (o.pushToken as string).trim();
  if (!/^[0-9a-fA-F]{16,512}$/.test(pushToken)) return 'bad pushToken';
  if (o.apnsEnv !== 'development' && o.apnsEnv !== 'production') return 'bad apnsEnv';
  const trainNum = (o.trainNum as string).trim();
  if (!/^[A-Za-z0-9]{1,8}$/.test(trainNum)) return 'bad trainNum';
  return {
    activityId,
    pushToken,
    apnsEnv: o.apnsEnv as ApnsEnv,
    trainNum,
    trainID: (o.trainID as string).trim(),
    stationCode: (o.stationCode as string).trim().toUpperCase(),
    createdAt: 0,
    lastPushAt: 0,
    lastStateHash: '',
    lastState: null,
  };
}

export function makeHandler(deps: Deps, secrets: Secrets): http.RequestListener {
  const json = (res: http.ServerResponse, code: number, body: unknown) => {
    res.writeHead(code, { 'content-type': 'application/json' });
    res.end(JSON.stringify(body));
  };
  const readBody = (req: http.IncomingMessage) =>
    new Promise<string>((resolve, reject) => {
      let s = '';
      req.setEncoding('utf8');
      req.on('data', (c: string) => {
        s += c;
        if (s.length > 64 * 1024) reject(new Error('too large'));
      });
      req.on('end', () => resolve(s));
      req.on('error', reject);
    });
  const appAuthed = (req: http.IncomingMessage) => {
    const h = req.headers.authorization ?? '';
    return h.startsWith('Bearer ') && safeEqual(h.slice(7), secrets.appSecret);
  };

  return async (req, res) => {
    try {
      const url = new URL(req.url ?? '/', 'http://x');
      const path = url.pathname;
      if (req.method === 'GET' && path === '/health') {
        res.writeHead(200, { 'content-type': 'text/plain' });
        return void res.end('ok');
      }
      if (req.method === 'POST' && path === '/tick') {
        const h = req.headers['x-tick-secret'];
        if (typeof h !== 'string' || !safeEqual(h, secrets.tickSecret)) return json(res, 401, { error: 'unauthorized' });
        const r = await runTick(deps);
        log('tick', { ...r });
        return json(res, 200, r);
      }
      if (path === '/trips' || path.startsWith('/trips/')) {
        if (!appAuthed(req)) return json(res, 401, { error: 'unauthorized' });
        if (req.method === 'POST' && path === '/trips') {
          let parsed: unknown;
          try {
            parsed = JSON.parse(await readBody(req));
          } catch {
            return json(res, 400, { error: 'invalid json' });
          }
          const t = validateTripBody(parsed);
          if (typeof t === 'string') return json(res, 400, { error: t });
          const existing = await deps.store.get(t.activityId);
          const trip: Trip = existing
            ? { ...existing, ...t, createdAt: existing.createdAt, lastPushAt: existing.lastPushAt, lastStateHash: existing.lastStateHash, lastState: existing.lastState }
            : { ...t, createdAt: deps.now() };
          await deps.store.put(trip);
          try {
            await pushNow(trip, deps);
          } catch (e) {
            log('immediate push failed', { activityId: trip.activityId, err: String(e) });
          }
          return json(res, 200, { ok: true });
        }
        if (req.method === 'DELETE' && path.startsWith('/trips/')) {
          const id = decodeURIComponent(path.slice('/trips/'.length));
          if (id) await deps.store.delete(id);
          return json(res, 200, { ok: true });
        }
      }
      json(res, 404, { error: 'not found' });
    } catch (e) {
      log('handler error', { err: String(e) });
      json(res, 500, { error: 'internal' });
    }
  };
}

function main() {
  const apns = new HttpApnsSender({
    keyP8: need('APNS_KEY_P8'),
    keyId: need('APNS_KEY_ID'),
    teamId: need('APNS_TEAM_ID'),
    bundleId: process.env.APP_BUNDLE_ID || 'com.somefamilies.amtracker',
  });
  const deps: Deps = {
    store: new FirestoreStore(process.env.GOOGLE_CLOUD_PROJECT),
    apns,
    fetchRuns,
    now: Date.now,
    log,
  };
  const server = http.createServer(
    makeHandler(deps, { appSecret: need('APP_SHARED_SECRET'), tickSecret: need('TICK_SECRET') }),
  );
  const port = Number(process.env.PORT || 8080);
  server.listen(port, () => log('listening', { port }));
  process.on('SIGTERM', () => {
    apns.close();
    server.close(() => process.exit(0));
  });
}

import { fileURLToPath } from 'node:url';
if (process.argv[1] === fileURLToPath(import.meta.url)) main();
