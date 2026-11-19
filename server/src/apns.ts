import crypto from 'node:crypto';
import http2 from 'node:http2';
import type { ApnsEnv, ContentState } from './types.js';

export const STALE_SECONDS = 15 * 60;
export const END_DISMISS_SECONDS = 15 * 60;

export interface ApnsAps {
  timestamp: number;
  event: 'update' | 'end';
  'content-state': ContentState;
  'stale-date': number;
  'dismissal-date'?: number;
}
export interface ApnsBody {
  aps: ApnsAps;
}

export function buildPayload(state: ContentState, nowSec: number, event: 'update' | 'end'): ApnsBody {
  const timestamp = Math.floor(nowSec);
  const aps: ApnsAps = {
    timestamp,
    event,
    'content-state': state,
    'stale-date': timestamp + STALE_SECONDS,
  };
  if (event === 'end') aps['dismissal-date'] = timestamp + END_DISMISS_SECONDS;
  return { aps };
}

/** 10 when label/phase changes or delay changes by >= 5 min, else 5. */
export function choosePriority(prev: ContentState | null, next: ContentState): 5 | 10 {
  if (!prev) return 10;
  if (prev.statusLabel !== next.statusLabel || prev.phase !== next.phase) return 10;
  if (Math.abs(prev.delayMinutes - next.delayMinutes) >= 5) return 10;
  return 5;
}

export interface ApnsRequest {
  pushToken: string;
  apnsEnv: ApnsEnv;
  body: ApnsBody;
  priority: 5 | 10;
}
export interface ApnsResult {
  status: number;
  reason?: string;
}
export interface ApnsSender {
  send(req: ApnsRequest): Promise<ApnsResult>;
}

export function apnsHost(env: ApnsEnv): string {
  return env === 'development' ? 'api.sandbox.push.apple.com' : 'api.push.apple.com';
}

export function apnsHeaders(topicBundleId: string, priority: 5 | 10, jwt: string): Record<string, string> {
  return {
    'apns-push-type': 'liveactivity',
    'apns-topic': `${topicBundleId}.push-type.liveactivity`,
    'apns-priority': String(priority),
    authorization: `bearer ${jwt}`,
  };
}

/** True if the APNs response means the token is dead and the trip should be deleted. */
export function isDeadToken(r: ApnsResult): boolean {
  if (r.status === 410) return true;
  return r.status === 400 && (r.reason === 'BadDeviceToken' || r.reason === 'ExpiredToken');
}

const b64url = (b: Buffer | string) => Buffer.from(b).toString('base64url');

export function signJwt(pem: string, keyId: string, teamId: string, iatSec: number): string {
  const header = b64url(JSON.stringify({ alg: 'ES256', kid: keyId }));
  const claims = b64url(JSON.stringify({ iss: teamId, iat: iatSec }));
  const data = `${header}.${claims}`;
  const sig = crypto.sign('sha256', Buffer.from(data), { key: pem, dsaEncoding: 'ieee-p1363' });
  return `${data}.${b64url(sig)}`;
}

export interface ApnsConfig {
  keyP8: string;
  keyId: string;
  teamId: string;
  bundleId: string;
}

const JWT_TTL_MS = 50 * 60_000;

export class HttpApnsSender implements ApnsSender {
  private sessions = new Map<string, http2.ClientHttp2Session>();
  private jwt: { token: string; at: number } | null = null;
  private pem: string;

  constructor(
    private cfg: ApnsConfig,
    private now: () => number = Date.now,
  ) {
    this.pem = cfg.keyP8.includes('\\n') ? cfg.keyP8.replace(/\\n/g, '\n') : cfg.keyP8;
  }

  getJwt(): string {
    const n = this.now();
    if (!this.jwt || n - this.jwt.at > JWT_TTL_MS) {
      this.jwt = { token: signJwt(this.pem, this.cfg.keyId, this.cfg.teamId, Math.floor(n / 1000)), at: n };
    }
    return this.jwt.token;
  }

  private session(host: string): http2.ClientHttp2Session {
    const existing = this.sessions.get(host);
    if (existing && !existing.closed && !existing.destroyed) return existing;
    const s = http2.connect(`https://${host}`);
    const drop = () => {
      if (this.sessions.get(host) === s) this.sessions.delete(host);
    };
    s.on('error', drop);
    s.on('close', drop);
    s.on('goaway', drop);
    s.setTimeout(5 * 60_000, () => s.close());
    this.sessions.set(host, s);
    return s;
  }

  private dropSession(host: string): void {
    const s = this.sessions.get(host);
    this.sessions.delete(host);
    s?.close();
  }

  async send(req: ApnsRequest): Promise<ApnsResult> {
    const first = await this.sendOnce(req);
    if (first.reason !== 'TopicDisallowed') return first;
    return this.sendOnce(req); // one retry on a fresh connection
  }

  private sendOnce(req: ApnsRequest): Promise<ApnsResult> {
    const host = apnsHost(req.apnsEnv);
    const payload = JSON.stringify(req.body);
    return new Promise<ApnsResult>((resolve, reject) => {
      let settled = false;
      const done = (fn: () => void) => {
        if (!settled) {
          settled = true;
          fn();
        }
      };
      let stream: http2.ClientHttp2Stream;
      try {
        stream = this.session(host).request({
          ':method': 'POST',
          ':path': `/3/device/${req.pushToken}`,
          ...apnsHeaders(this.cfg.bundleId, req.priority, this.getJwt()),
          'content-type': 'application/json',
        });
      } catch (e) {
        this.sessions.delete(host);
        return reject(e);
      }
      let status = 0;
      let data = '';
      stream.setEncoding('utf8');
      stream.setTimeout(10_000, () => {
        stream.close(http2.constants.NGHTTP2_CANCEL);
        done(() => reject(new Error('APNs request timeout')));
      });
      stream.on('response', (h) => {
        status = Number(h[':status'] ?? 0);
      });
      stream.on('data', (c: string) => (data += c));
      stream.on('error', (e) => done(() => reject(e)));
      stream.on('end', () =>
        done(() => {
          let reason: string | undefined;
          try {
            reason = data ? (JSON.parse(data) as { reason?: string }).reason : undefined;
          } catch {
            /* ignore */
          }
          if (status === 403 && reason?.includes('ProviderToken')) this.jwt = null;
          // APNs evaluates topic permissions per connection; a connection opened before the
          // App ID gained push keeps returning TopicDisallowed. Drop it so the retry reconnects.
          if (reason === 'TopicDisallowed') this.dropSession(host);
          resolve({ status, reason });
        }),
      );
      stream.end(payload);
    });
  }

  close(): void {
    for (const s of this.sessions.values()) s.close();
    this.sessions.clear();
  }
}
