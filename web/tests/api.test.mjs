import assert from 'node:assert/strict';
import { afterEach, test } from 'node:test';
import { clearHistoryCache, loadHistory } from '../src/api.ts';

const originalFetch = globalThis.fetch;
const params = { metric: 'heart_rate', from: '2026-10-09T00:00:00Z', to: '2026-10-10T00:00:00Z', timezone: 'UTC', bucket: 'hour' };
const stamp = '2026-10-10T01:00:00Z';
const sample = (value, start) => ({ value, start, end: start, unit: 'bpm', source: 'Apple Health' });
afterEach(() => { globalThis.fetch = originalFetch; clearHistoryCache(); });

test('day loads only sample pages and derives exact statistics and latest', async () => {
  const calls = [];
  globalThis.fetch = async url => {
    calls.push(url);
    const query = new URL(url, 'https://example.test');
    assert.equal(query.pathname, '/v1/samples');
    assert.equal(query.searchParams.get('limit'), '500');
    return Response.json(query.searchParams.has('cursor')
      ? { samples: [sample(80, '2026-10-09T02:00:00Z')], next_cursor: null, last_ingestion: stamp }
      : { samples: [sample(60, '2026-10-09T01:00:00Z')], next_cursor: 'next', last_ingestion: stamp });
  };
  const result = await loadHistory(params, true, new AbortController().signal);
  assert.equal(calls.length, 2);
  assert.deepEqual(result.summary.summary, { count: 2, min: 60, max: 80, average: 70 });
  assert.equal(result.summary.latest.value, 80);
  assert.equal(result.summary.last_ingestion, stamp);
  assert.equal(await loadHistory(params, true, new AbortController().signal), result);
  assert.equal(calls.length, 2);
  clearHistoryCache();
  await loadHistory(params, true, new AbortController().signal);
  assert.equal(calls.length, 4);
});

test('week/month requests only summaries and reuses loaded views', async () => {
  const calls = [];
  globalThis.fetch = async url => {
    calls.push(url);
    assert.equal(new URL(url, 'https://example.test').pathname, '/v1/summaries');
    return Response.json({ buckets: [], summary: { count: 0, min: null, max: null, average: null }, latest: null, last_ingestion: stamp });
  };
  await loadHistory(params, false, new AbortController().signal);
  await loadHistory({ ...params, metric: 'hrv_sdnn' }, false, new AbortController().signal);
  await loadHistory(params, false, new AbortController().signal);
  assert.equal(calls.length, 2);
});

test('empty day statistics are null', async () => {
  globalThis.fetch = async () => Response.json({ samples: [], next_cursor: null, last_ingestion: null });
  const result = await loadHistory(params, true, new AbortController().signal);
  assert.deepEqual(result.summary.summary, { count: 0, min: null, max: null, average: null });
  assert.equal(result.summary.latest, null);
});

test('failures are not retried automatically or cached', async () => {
  let calls = 0;
  globalThis.fetch = async () => { calls++; return new Response(null, { status: 503 }); };
  await assert.rejects(loadHistory(params, true, new AbortController().signal));
  assert.equal(calls, 1);
  await assert.rejects(loadHistory(params, true, new AbortController().signal));
  assert.equal(calls, 2);
});

test('aborted loads cannot populate the cache', async () => {
  const controller = new AbortController();
  let calls = 0;
  globalThis.fetch = async () => {
    calls++;
    controller.abort();
    return Response.json({ samples: [], next_cursor: null, last_ingestion: null });
  };
  await loadHistory(params, true, controller.signal);
  await loadHistory(params, true, new AbortController().signal);
  assert.equal(calls, 2);
});
