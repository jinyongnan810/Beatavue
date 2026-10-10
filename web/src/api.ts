export type Metric = 'heart_rate' | 'hrv_sdnn';
export type Sample = { value: number; unit: string; start: string; end: string; source: string };
export type Stats = { count: number; min: number | null; max: number | null; average: number | null };
export type Bucket = Stats & { start: string };
export type Summary = { buckets: Bucket[]; summary: Stats; latest: Sample | null; unit: string; bucket: string; timezone: string };

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
