import { readFileSync } from 'node:fs';
import type { Train } from './types.js';

export function fixtureRuns(): Train[] {
  const j = JSON.parse(readFileSync('test/fixtures/train6.json', 'utf8')) as Record<string, Train[]>;
  return j['6']!;
}
export function run(id: string): Train {
  return structuredClone(fixtureRuns().find((t) => t.trainID === id)!);
}
