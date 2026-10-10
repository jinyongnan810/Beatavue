export type Metric = 'heart_rate' | 'hrv_sdnn';
export type Sample = { value: number; unit: string; start: string; end: string; source: string };
export type Stats = { count: number; min: number | null; max: number | null; average: number | null };
export type Bucket = Stats & { start: string };
export type Summary = { buckets: Bucket[]; summary: Stats; latest: Sample | null; unit: string; bucket: string; timezone: string; last_ingestion: string | null };
type SamplePage = { samples: Sample[]; next_cursor: string | null; last_ingestion: string | null };
type History = { summary: Summary; samples: Sample[] };
// A bounded cache for this page visit. Refresh explicitly discards every view.
const historyCache = new Map<string, History>();
export const clearHistoryCache = () => historyCache.clear();

export async function loadHistory(params: Record<string, string>, raw: boolean, signal: AbortSignal): Promise<History> {
  const key = JSON.stringify([raw, params.metric, params.from, params.to, raw ? null : params.timezone, raw ? null : params.bucket]);
  const cached = historyCache.get(key);
  if (cached) return cached;
  let result: History;
  if (raw) {
    const samples: Sample[] = [];
    let cursor: string | null = null;
    let ingestion: string | null = null;
    do {
      const page: SamplePage = await get('/v1/samples', {
        metric: params.metric, from: params.from, to: params.to,
        limit: '500', ...(cursor ? { cursor } : {}),
      }, signal);
      if (!samples.length) ingestion = page.last_ingestion;
      samples.push(...page.samples);
      cursor = page.next_cursor;
      if (samples.length > 20000 || (samples.length === 20000 && cursor)) throw new Error('Too many samples to display.');
    } while (cursor);
    let min: number | null = null;
    let max: number | null = null;
    let sum = 0;
    for (const sample of samples) {
      min = min === null ? sample.value : Math.min(min, sample.value);
      max = max === null ? sample.value : Math.max(max, sample.value);
      sum += sample.value;
    }
    result = { samples, summary: {
      buckets: [], summary: { count: samples.length, min, max, average: samples.length ? sum / samples.length : null },
      latest: samples.at(-1) ?? null, unit: params.metric === 'heart_rate' ? 'bpm' : 'ms',
      bucket: params.bucket, timezone: params.timezone, last_ingestion: ingestion,
    } };
  } else {
    result = { summary: await get<Summary>('/v1/summaries', params, signal), samples: [] };
  }
  if (!signal.aborted) {
    historyCache.set(key, result);
    if (historyCache.size > 12) historyCache.delete(historyCache.keys().next().value!);
  }
  return result;
}

export async function get<T>(path: string, params: Record<string, string>, signal: AbortSignal): Promise<T> {
  const response = await fetch(`${path}?${new URLSearchParams(params)}`, { signal });
  if (!response.ok) {
    const messages: Record<number, string> = {
      400: 'This date range or timezone could not be queried.',
      409: 'Published data changed. Refresh to load the new dataset.',
      422: 'Too many measurements in this range. Select a shorter period.',
      429: 'The public API is busy. Please try again shortly.',
      503: 'Cloud data is temporarily unavailable. Please try again.',
    };
    throw new Error(messages[response.status] ?? `Could not load history (${response.status}).`);
  }
  return response.json() as Promise<T>;
}
