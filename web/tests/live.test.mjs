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
const flush = async () => { for (let i = 0; i < 8; i++) await new Promise(resolve => setImmediate(resolve)); };
const headers = async () => ({ 'X-Firebase-AppCheck': 'test-attestation' });

test('stream sends attestation, parses split events, reconnects and aborts on cleanup', async t => {
  t.mock.timers.enable({ apis: ['setTimeout'] });
  t.mock.method(Math, 'random', () => 0);
  const streams = [], requests = [], readings = [], connections = [];
  t.mock.method(globalThis, 'fetch', async (url, options) => {
    assert.equal(url, '/v1/live');
    assert.equal(options.headers['X-Firebase-AppCheck'], 'test-attestation');
    requests.push(options);
    return new Response(new ReadableStream({ start(controller) { streams.push(controller); } }),
      { headers: { 'Content-Type': 'text/event-stream' } });
  });
  const unsubscribe = subscribeLive(value => readings.push(value), value => connections.push(value), '/v1/live', headers);
  const send = text => streams.at(-1).enqueue(new TextEncoder().encode(text));
  await flush();
  send('event: live\r\ndata: ' + JSON.stringify(reading).slice(0, 12));
  await flush();
  assert.equal(readings.length, 0);
  send(JSON.stringify(reading).slice(12) + '\r\n\r\n');
  await flush();
  assert.deepEqual(readings, [reading]);
  assert.equal(connections.at(-1), true);
  send('event: reconnect\ndata: {}\n\n');
  await flush();
  t.mock.timers.tick(1000);
  await flush();
  assert.equal(requests.length, 2);
  unsubscribe();
  assert.equal(requests[1].signal.aborted, true);
  streams.at(-1).close();
  await flush();
  t.mock.timers.tick(60000);
  await flush();
  assert.equal(requests.length, 2);
});

test('rate limits honor Retry-After and do not spin on errors', async t => {
  t.mock.timers.enable({ apis: ['setTimeout'] });
  t.mock.method(Math, 'random', () => 0);
  let calls = 0;
  t.mock.method(globalThis, 'fetch', async () => {
    calls++;
    return new Response(null, { status: 429, headers: { 'Retry-After': '55' } });
  });
  const unsubscribe = subscribeLive(() => {}, () => {}, '/v1/live', headers);
  await flush();
  t.mock.timers.tick(54000);
  await flush();
  assert.equal(calls, 1);
  t.mock.timers.tick(1000);
  await flush();
  assert.equal(calls, 2);
  unsubscribe();
});

test('cleanup during attestation prevents a late network request', async t => {
  let resolve;
  const pending = new Promise(done => { resolve = done; });
  const fetch = t.mock.method(globalThis, 'fetch', async () => { throw new Error('Unexpected request'); });
  const unsubscribe = subscribeLive(() => {}, () => {}, '/v1/live', () => pending);
  unsubscribe();
  resolve(await headers());
  await flush();
  assert.equal(fetch.mock.callCount(), 0);
});
