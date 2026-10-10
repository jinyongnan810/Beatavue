import React, { useEffect, useMemo, useState } from 'react';
import { createRoot } from 'react-dom/client';
import { DateTime } from 'luxon';
import { get, type Bucket, type Metric, type Sample, type Summary } from './api';
import './style.css';

type Period = 'day' | 'week' | 'month';
type Point = { time: string; value: number; detail: string };
const units = { heart_rate: 'bpm', hrv_sdnn: 'ms' };
const labels = { heart_rate: 'Heart rate', hrv_sdnn: 'HRV (SDNN)' };
const number = (value: number | null | undefined) => value == null ? '—' : value.toLocaleString(undefined, { maximumFractionDigits: 1 });
const zones = [...new Set([Intl.DateTimeFormat().resolvedOptions().timeZone, 'Asia/Tokyo', 'UTC', 'America/New_York', 'Europe/London'])];

function Chart({ points, start, end, zone, unit, aggregated }: {
  points: Point[]; start: number; end: number; zone: string; unit: string; aggregated: boolean;
}) {
  const [selected, setSelected] = useState<Point | null>(null);
  useEffect(() => setSelected(null), [points]);
  const values = points.map(point => point.value);
  const min = Math.floor(Math.min(...values) * .9);
  const max = Math.max(min + 10, Math.ceil(Math.max(...values) * 1.1));
  const x = (time: string) => 65 + (DateTime.fromISO(time).toMillis() - start) / (end - start) * 865;
  const y = (value: number) => 260 - (value - min) / (max - min) * 220;
  const timestamp = (time: string) => DateTime.fromISO(time).setZone(zone).toFormat('MMM d, HH:mm:ss ZZZZ');
  if (!points.length) return <div className="empty"><span>♡</span><h2>No published measurements</h2><p>Try another date. New device readings may still be waiting to upload.</p></div>;
  return <>
    <svg className="chart" viewBox="0 0 960 315" role="group" aria-label={`${aggregated ? 'Sample averages' : 'Measured samples'} in ${unit}`}>
      {[0, 1, 2, 3, 4].map(tick => {
        const value = min + (max - min) * tick / 4;
        return <g key={tick}><line x1="65" x2="930" y1={y(value)} y2={y(value)} className="grid" /><text x="50" y={y(value) + 4} textAnchor="end">{number(value)}</text></g>;
      })}
      {[0, 1, 2, 3, 4].map(tick => <text key={tick} x={65 + tick / 4 * 865} y="295" textAnchor={tick === 0 ? 'start' : tick === 4 ? 'end' : 'middle'}>{DateTime.fromMillis(start + (end - start) * tick / 4).setZone(zone).toFormat(end - start < 90000000 ? 'HH:mm' : 'MMM d')}</text>)}
      {points.map((point, index) => <circle key={`${point.time}-${index}`} cx={x(point.time)} cy={y(point.value)} r={aggregated ? 5 : 3} tabIndex={0} role="button"
        onFocus={() => setSelected(point)} onClick={() => setSelected(point)} onMouseEnter={() => setSelected(point)}
        onKeyDown={event => { if (event.key === 'Enter' || event.key === ' ') setSelected(point); }}
        aria-label={`${number(point.value)} ${unit}, ${timestamp(point.time)}, ${point.detail}`}>
        <title>{number(point.value)} {unit} · {timestamp(point.time)} · {point.detail}</title>
      </circle>)}
    </svg>
    <p className="inspection" aria-live="polite">{selected ? `${number(selected.value)} ${unit} · ${timestamp(selected.time)} · ${selected.detail}` : 'Select a point to inspect its value and time.'}</p>
  </>;
}

function App() {
  const [metric, setMetric] = useState<Metric>('heart_rate');
  const [period, setPeriod] = useState<Period>('day');
  const [date, setDate] = useState(DateTime.local().toISODate()!);
  const [zone, setZone] = useState(zones[0]);
  const [revision, setRevision] = useState(0);
  const [summary, setSummary] = useState<Summary | null>(null);
  const [samples, setSamples] = useState<Sample[]>([]);
  const [ingestion, setIngestion] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const range = useMemo(() => {
    const selected = DateTime.fromISO(date, { zone });
    const start = selected.startOf(period);
    const end = start.plus(period === 'day' ? { days: 1 } : period === 'week' ? { weeks: 1 } : { months: 1 });
    return { start, end };
  }, [date, period, zone]);

  useEffect(() => {
    const controller = new AbortController();
    setLoading(true); setError(null); setSummary(null); setSamples([]);
    const params = { metric, from: range.start.toUTC().toISO()!, to: range.end.toUTC().toISO()!, timezone: zone, bucket: period === 'day' ? 'hour' : 'day' };
    async function load() {
      try {
        const [summaryResult, status] = await Promise.all([
          get<Summary>('/v1/summaries', params, controller.signal),
          get<{ last_ingestion: string | null }>('/v1/sync-status', {}, controller.signal),
        ]);
        const raw: Sample[] = [];
        if (period === 'day') {
          let cursor: string | null = null;
          do {
            const page: { samples: Sample[]; next_cursor: string | null } = await get('/v1/samples', { ...params, limit: '500', ...(cursor ? { cursor } : {}) }, controller.signal);
            raw.push(...page.samples); cursor = page.next_cursor;
            if (raw.length > 20000) throw new Error('Too many samples to display.');
          } while (cursor);
        }
        if (!controller.signal.aborted) { setSummary(summaryResult); setSamples(raw); setIngestion(status.last_ingestion); }
      } catch (failure) {
        if (!controller.signal.aborted) setError(failure instanceof Error ? failure.message : 'Could not load history.');
      } finally { if (!controller.signal.aborted) setLoading(false); }
    }
    void load();
    return () => controller.abort();
  }, [metric, period, range, zone, revision]);

  useEffect(() => {
    const timer = window.setInterval(() => { if (document.visibilityState === 'visible') setRevision(value => value + 1); }, 120000);
    return () => window.clearInterval(timer);
  }, []);

  const points: Point[] = period === 'day'
    ? samples.map(sample => ({ time: sample.start, value: sample.value, detail: sample.source }))
    : (summary?.buckets ?? []).map((bucket: Bucket) => ({ time: bucket.start, value: bucket.average!, detail: `Average of ${bucket.count} available samples · min ${number(bucket.min)} / max ${number(bucket.max)}` }));
  const move = (direction: number) => setDate(range.start.plus(period === 'day' ? { days: direction } : period === 'week' ? { weeks: direction } : { months: direction }).toISODate()!);
  const stats = summary?.summary;
  return <main>
    <header><a className="brand" href="/">♡ <span>Beatavue</span></a><span className="badge">Personal health journal</span></header>
    <section className="intro"><p className="eyebrow">A little closer to the rhythm</p><h1>Heart history,<br /><em>at a glance.</em></h1><p>One person’s Apple Health measurements. Shared openly, with room for the gaps.</p></section>
    <section className="panel" aria-label="History controls">
      <div className="controls"><div className="segments">{(['heart_rate', 'hrv_sdnn'] as Metric[]).map(value => <button key={value} aria-pressed={metric === value} onClick={() => setMetric(value)}>{labels[value]}</button>)}</div><button className="refresh" onClick={() => setRevision(value => value + 1)} disabled={loading}>↻ Refresh</button></div>
      <div className="navigation"><div className="segments periods">{(['day', 'week', 'month'] as Period[]).map(value => <button key={value} aria-pressed={period === value} onClick={() => setPeriod(value)}>{value}</button>)}</div><div className="date"><button aria-label="Previous period" onClick={() => move(-1)}>‹</button><input type="date" aria-label="Selected date" value={date} max={DateTime.now().setZone(zone).toISODate()!} onChange={event => { if (event.target.value) setDate(event.target.value); }} /><button aria-label="Next period" disabled={range.end.toMillis() > Date.now()} onClick={() => move(1)}>›</button></div><select aria-label="Display timezone" value={zone} onChange={event => setZone(event.target.value)}>{zones.map(value => <option key={value}>{value}</option>)}</select></div>
      <div className="chart-heading"><div><p className="eyebrow">{range.start.toFormat('MMM d')} – {range.end.minus({ days: 1 }).toFormat('MMM d, yyyy')}</p><h2>{labels[metric]} <small>{units[metric]}</small></h2></div><span>{period === 'day' ? 'Actual measurements' : 'Daily sample averages'}</span></div>
      {loading ? <div className="empty" role="status">Loading published history…</div> : error ? <div className="empty" role="alert"><h2>History is unavailable</h2><p>{error}</p><button onClick={() => setRevision(value => value + 1)}>Try again</button></div> : <Chart points={points} start={range.start.toMillis()} end={range.end.toMillis()} zone={zone} unit={units[metric]} aggregated={period !== 'day'} />}
      <div className="stats">{[['Samples', stats?.count], ['Minimum', stats?.min], ['Maximum', stats?.max], ['Sample average', stats?.average]].map(([label, value]) => <div key={label as string}><span>{label}</span><strong>{number(value as number | null | undefined)} <small>{label === 'Samples' ? '' : units[metric]}</small></strong></div>)}</div>
      <p className="note">Averages give equal weight to available samples. Measurements are intermittent; gaps do not imply continuous recording. Overlapping sources are retained.</p>
    </section>
    <section className="footnotes"><div><p className="eyebrow">Latest in this period</p><strong>{summary?.latest ? `${number(summary.latest.value)} ${units[metric]}` : 'No measurement'}</strong><p>{summary?.latest ? DateTime.fromISO(summary.latest.start).setZone(zone).toFormat('MMM d, yyyy · HH:mm:ss ZZZZ') : 'Choose a period with published samples.'}</p></div><div><p className="eyebrow">Last server ingestion</p><strong>{ingestion ? DateTime.fromISO(ingestion).setZone(zone).toFormat('MMM d, yyyy · HH:mm') : 'No upload yet'}</strong><p>Recent device measurements may not have uploaded yet.</p></div></section>
    <footer>Beatavue · Historical measurements, not medical guidance. HRV is SDNN in milliseconds. Live workout readings stay on the iPhone and Watch.</footer>
  </main>;
}

createRoot(document.getElementById('root')!).render(<React.StrictMode><App /></React.StrictMode>);
