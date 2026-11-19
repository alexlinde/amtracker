import { Firestore } from '@google-cloud/firestore';
import type { Trip } from './types.js';

export interface TripStore {
  get(activityId: string): Promise<Trip | null>;
  put(trip: Trip): Promise<void>;
  delete(activityId: string): Promise<void>;
  list(): Promise<Trip[]>;
  count(): Promise<number>;
}

export class MemoryStore implements TripStore {
  readonly trips = new Map<string, Trip>();
  async get(id: string) {
    const t = this.trips.get(id);
    return t ? structuredClone(t) : null;
  }
  async put(trip: Trip) {
    this.trips.set(trip.activityId, structuredClone(trip));
  }
  async delete(id: string) {
    this.trips.delete(id);
  }
  async list() {
    return [...this.trips.values()].map((t) => structuredClone(t));
  }
  async count() {
    return this.trips.size;
  }
}

export class FirestoreStore implements TripStore {
  private col;
  constructor(projectId?: string) {
    const db = new Firestore(projectId ? { projectId } : {});
    this.col = db.collection('trips');
  }
  async get(id: string) {
    const snap = await this.col.doc(id).get();
    return snap.exists ? (snap.data() as Trip) : null;
  }
  async put(trip: Trip) {
    // Firestore rejects undefined fields.
    await this.col.doc(trip.activityId).set(JSON.parse(JSON.stringify(trip)));
  }
  async delete(id: string) {
    await this.col.doc(id).delete();
  }
  async list() {
    const snap = await this.col.get();
    return snap.docs.map((d) => d.data() as Trip);
  }
  async count() {
    const snap = await this.col.count().get();
    return snap.data().count;
  }
}
