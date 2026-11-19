export interface Station {
  name?: string;
  code?: string;
  tz?: string;
  schArr?: string;
  schDep?: string;
  arr?: string;
  dep?: string;
  status?: string;
}

export interface Train {
  routeName?: string;
  trainNum?: string;
  trainID?: string;
  trainState?: string;
  origCode?: string;
  origName?: string;
  originTZ?: string;
  lat?: number;
  lon?: number;
  heading?: string;
  velocity?: number;
  destName?: string;
  eventName?: string;
  lastValTS?: string;
  updatedAt?: string;
  stations?: Station[];
}

/** Matches docs/live-activity-contract.md ContentState exactly. All fields always present. */
export interface ContentState {
  phase: 'scheduled' | 'enroute' | 'atStation' | 'departed' | 'unknown';
  statusLabel: string;
  statusColor: 'green' | 'orange' | 'red' | 'gray';
  etaEpoch: number;
  scheduledEpoch: number;
  delayMinutes: number;
  nextStopName: string;
  stopsAway: number;
  lat: number;
  lon: number;
  speedMph: number;
  updatedEpoch: number;
}

export type ApnsEnv = 'development' | 'production';

export interface TripRequest {
  activityId: string;
  pushToken: string;
  apnsEnv: ApnsEnv;
  trainNum: string;
  trainID: string;
  stationCode: string;
}

/** Firestore doc: request fields + bookkeeping. Times are epoch milliseconds. */
export interface Trip extends TripRequest {
  createdAt: number;
  lastPushAt: number;
  lastStateHash: string;
  lastState: ContentState | null;
  /** Additive: first time we observed the finished condition without a timestamp in the feed. */
  finishedAt?: number;
  /** Additive: consecutive ticks the locked run was missing from the feed (guards transient empty responses). */
  missCount?: number;
}
