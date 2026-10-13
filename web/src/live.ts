export type LiveReading = { heart_rate: number | null; updating: boolean; measured_at: string | null; updated_at: number | null };

export function isLive(reading: LiveReading | null, connected: boolean, now: number): boolean {
  if (!connected || !reading?.updating || reading.heart_rate == null || !reading.measured_at) return false;
  const age = now - Date.parse(reading.measured_at);
  return Number.isFinite(reading.heart_rate) && reading.heart_rate > 0 && age >= -30000 && age <= 30000;
}

// The public API relays RTDB events. No upload token or database credential reaches the browser.
export function subscribeLive(onReading: (value: LiveReading) => void, onConnection: (connected: boolean) => void, url = "/v1/live"): () => void {
  let source: EventSource;
  let disposed = false;
  function connect() {
    if (disposed) return;
    source = new EventSource(url);
    source.addEventListener('live', event => {
      try {
        const value = JSON.parse((event as MessageEvent).data) as LiveReading;
        if (typeof value.updating !== 'boolean') throw new Error('Invalid live state');
        onReading(value);
        onConnection(true);
      } catch { onConnection(false); }
    });
    source.addEventListener('unavailable', () => onConnection(false));
    source.addEventListener('reconnect', () => { source.close(); connect(); });
    source.onerror = () => onConnection(false);
  }
  connect();
  return () => { disposed = true; source.close(); };
}
