// Usage: npm run dryrun -- <trainNum> <stationCode> [--file fixture.json] [--end]
import { readFileSync } from 'node:fs';
import { apnsHeaders, apnsHost, buildPayload, choosePriority } from './apns.js';
import { fetchRuns } from './amtraker.js';
import { selectRun } from './selection.js';
import { computeContentState } from './state.js';
import type { Train } from './types.js';

async function main() {
  const args = process.argv.slice(2);
  const fi = args.indexOf('--file');
  const file = fi >= 0 ? args.splice(fi, 2)[1] : undefined;
  const ei = args.indexOf('--end');
  const asEnd = ei >= 0;
  if (ei >= 0) args.splice(ei, 1);
  const [num, code] = args;
  if (!num || !code) {
    console.error('usage: npm run dryrun -- <trainNum> <stationCode> [--file fixture.json] [--end]');
    process.exit(2);
  }
  let runs: Train[];
  if (file) {
    const body = JSON.parse(readFileSync(file, 'utf8')) as Record<string, Train[]>;
    runs = body[num] ?? Object.values(body)[0] ?? [];
  } else {
    runs = await fetchRuns(num);
  }
  const now = Date.now();
  const sel = selectRun(runs, code, now);
  if (!sel) {
    console.error(runs.length ? `Train ${num} doesn't stop at ${code}` : `Train ${num} isn't running right now`);
    process.exit(1);
  }
  const state = computeContentState(sel.train, code)!;
  console.log(`# selected run: ${sel.train.trainID} (${sel.train.routeName}) at ${sel.station.name} [${sel.station.code}]`);
  console.log('# ContentState');
  console.log(JSON.stringify(state, null, 2));
  const body = buildPayload(state, now / 1000, asEnd ? 'end' : 'update');
  console.log(`# APNs request (NOT sent): POST https://${apnsHost('production')}/3/device/<token>`);
  console.log(
    JSON.stringify(apnsHeaders('com.somefamilies.amtracker', choosePriority(null, state), '<jwt>'), null, 2),
  );
  console.log('# APNs body');
  console.log(JSON.stringify(body, null, 2));
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
