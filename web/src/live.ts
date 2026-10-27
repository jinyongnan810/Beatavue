import { appCheckHeaders } from './appCheck.ts';

export type LiveReading = { heart_rate: number | null; updating: boolean; measured_at: string | null; updated_at: number | null };

export function isLive(reading: LiveReading | null, connected: boolean, now: number): boolean {
  if (!connected || !reading?.updating || reading.heart_rate == null || !reading.measured_at) return false;
  const age = now - Date.parse(reading.measured_at);
  return Number.isFinite(reading.heart_rate) && reading.heart_rate > 0 && age >= -30000 && age <= 30000;
}

// The public API relays RTDB events. No upload token or database credential reaches the browser.
export function subscribeLive(onReading: (value: LiveReading) => void, onConnection: (connected: boolean) => void, url = "/v1/live", headers = appCheckHeaders): () => void {
  const controller = new AbortController();
  let disposed = false;
  let timer: ReturnType<typeof setTimeout> | undefined;
  let retry = 1000;
  async function connect() {
    let delay = retry;
    let reader: ReadableStreamDefaultReader<string> | undefined;
    try {
      const authHeaders = await headers();
      if (disposed) return;
      const response = await fetch(url, { headers: authHeaders, signal: controller.signal, cache: 'no-store' });
      if (!response.ok) {
        const seconds = Number(response.headers.get('Retry-After'));
        if (Number.isFinite(seconds) && seconds > 0) delay = Math.min(seconds * 1000, 43200000);
        throw new Error('Live stream unavailable');
      }
      if (!response.body || !response.headers.get('Content-Type')?.startsWith('text/event-stream')) throw new Error('Invalid live stream');
      reader = response.body.pipeThrough(new TextDecoderStream()).getReader();
      let buffer = '';
      let reconnect = false;
      while (!disposed && !reconnect) {
        const { value, done } = await reader.read();
        if (done) break;
        buffer += value;
        if (buffer.length > 65536) throw new Error('Live event too large');
        let boundary: RegExpExecArray | null;
        while ((boundary = /\r?\n\r?\n/.exec(buffer))) {
          const frame = buffer.slice(0, boundary.index);
          buffer = buffer.slice(boundary.index + boundary[0].length);
          let event = 'message';
          const data: string[] = [];
          for (const line of frame.split(/\r?\n/)) {
            if (line.startsWith('event:')) event = line.slice(6).trim();
            if (line.startsWith('data:')) data.push(line.slice(5).replace(/^ /, ''));
          }
          if (event === 'reconnect') { reconnect = true; delay = 1000; break; }
          if (event === 'unavailable') onConnection(false);
          if (event === 'live') {
            const reading = JSON.parse(data.join('\n')) as LiveReading;
            if (!reading || typeof reading.updating !== 'boolean') throw new Error('Invalid live state');
            onReading(reading);
            onConnection(true);
            retry = 1000;
            delay = 1000;
          }
        }
      }
    } catch {
      retry = Math.min(retry * 2, 60000);
    } finally {
      await reader?.cancel().catch(() => {});
      if (!disposed) {
        onConnection(false);
        timer = setTimeout(() => { void connect(); }, delay + Math.floor(Math.random() * 500));
      }
    }
  }
  void connect();
  return () => { disposed = true; controller.abort(); clearTimeout(timer); };
}
