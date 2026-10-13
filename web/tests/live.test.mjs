import assert from 'node:assert/strict';
import { test } from 'node:test';
import { isLive, subscribeLive } from '../src/live.ts';

const now = Date.now();
const reading = { heart_rate: 75, updating: true, measured_at: new Date(now).toISOString(), updated_at: now };
test('live display requires a connected, fresh, active valid reading', () => {
  assert.equal(isLive(reading, true, now), true);
  for (const [value, connected, time] of [[null, true, now], [reading, false, now],
    [{ ...reading, updating: false }, true, now], [reading, true, now + 31000],
    [{ ...reading, heart_rate: NaN }, true, now], [{ ...reading, measured_at: 'bad' }, true, now]]) {
    assert.equal(isLive(value, connected, time), false);
  }
});
test('subscription reconnects deliberately, reports errors and closes on cleanup', () => {
  const original = globalThis.EventSource;
  const sources = [];
  globalThis.EventSource = class {
    callbacks = {}; closed = false;
    constructor(url) { assert.equal(url, '/v1/live'); sources.push(this); }
    addEventListener(name, callback) { this.callbacks[name] = callback; }
    close() { this.closed = true; }
  };
  try {
    const readings = [], connections = [];
    const unsubscribe = subscribeLive(value => readings.push(value), value => connections.push(value));
    sources[0].callbacks.live({ data: JSON.stringify(reading) });
    assert.deepEqual(readings, [reading]);
    assert.deepEqual(connections, [true]);
    sources[0].callbacks.reconnect();
    assert.equal(sources.length, 2);
    assert.equal(sources[0].closed, true);
    sources[1].onerror();
    assert.equal(connections.at(-1), false);
    unsubscribe();
    assert.equal(sources[1].closed, true);
  } finally { globalThis.EventSource = original; }
});
