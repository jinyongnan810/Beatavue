import React, { useEffect, useMemo, useState } from 'react';
import { createRoot } from 'react-dom/client';
import { DateTime } from 'luxon';
import { clearHistoryCache, HistoryError, loadHistory, type Bucket, type Metric, type Sample, type Summary } from './api';
import { dateFormats, languageStorageKey, resolveLanguage, translations, type Language } from './i18n';
import './style.css';

type Period = 'day' | 'week' | 'month';
type Point = { time: string; value: number; detail: string };
const units = { heart_rate: 'bpm', hrv_sdnn: 'ms' };
const formatNumber = (value: number | null | undefined, language: Language) => value == null ? '—' : value.toLocaleString(language, { maximumFractionDigits: 1 });
const zones = [...new Set([Intl.DateTimeFormat().resolvedOptions().timeZone, 'Asia/Tokyo', 'UTC', 'America/New_York', 'Europe/London'])];

function Chart({ points, start, end, zone, unit, aggregated, language }: {
  points: Point[]; start: number; end: number; zone: string; unit: string; aggregated: boolean; language: Language;
}) {
  const t = translations[language];
  const formats = dateFormats[language];
  const number = (value: number | null | undefined) => formatNumber(value, language);
  const [selected, setSelected] = useState<Point | null>(null);
  useEffect(() => setSelected(null), [points]);
  const values = points.map(point => point.value);
  const min = Math.floor(Math.min(...values) * .9);
  const max = Math.max(min + 10, Math.ceil(Math.max(...values) * 1.1));
  const x = (time: string) => 65 + (DateTime.fromISO(time).toMillis() - start) / (end - start) * 865;
  const y = (value: number) => 260 - (value - min) / (max - min) * 220;
  const timestamp = (time: string) => DateTime.fromISO(time).setZone(zone).setLocale(language).toFormat(formats.timestamp);
  if (!points.length) return <div className="empty"><span>♡</span><h2>{t.emptyTitle}</h2><p>{t.emptyNote}</p></div>;
  return <>
    <svg className="chart" viewBox="0 0 960 315" role="group" aria-label={t.chartLabel(aggregated ? t.sampleAverages : t.measuredSamples, unit)}>
      {[0, 1, 2, 3, 4].map(tick => {
        const value = min + (max - min) * tick / 4;
        return <g key={tick}><line x1="65" x2="930" y1={y(value)} y2={y(value)} className="grid" /><text x="50" y={y(value) + 4} textAnchor="end">{number(value)}</text></g>;
      })}
      {[0, 1, 2, 3, 4].map(tick => <text key={tick} x={65 + tick / 4 * 865} y="295" textAnchor={tick === 0 ? 'start' : tick === 4 ? 'end' : 'middle'}>{DateTime.fromMillis(start + (end - start) * tick / 4).setZone(zone).setLocale(language).toFormat(end - start < 90000000 ? 'HH:mm' : formats.short)}</text>)}
      {points.map((point, index) => <circle key={`${point.time}-${index}`} cx={x(point.time)} cy={y(point.value)} r={aggregated ? 5 : 3} tabIndex={0} role="button"
        onFocus={() => setSelected(point)} onClick={() => setSelected(point)} onMouseEnter={() => setSelected(point)}
        onKeyDown={event => { if (event.key === 'Enter' || event.key === ' ') setSelected(point); }}
        aria-label={`${number(point.value)} ${unit}, ${timestamp(point.time)}, ${point.detail}`}>
        <title>{number(point.value)} {unit} · {timestamp(point.time)} · {point.detail}</title>
      </circle>)}
    </svg>
    <p className="inspection" aria-live="polite">{selected ? `${number(selected.value)} ${unit} · ${timestamp(selected.time)} · ${selected.detail}` : t.inspect}</p>
  </>;
}

function App() {
  const [language, setLanguage] = useState<Language>(() => {
    let saved: string | null = null;
    try { saved = localStorage.getItem(languageStorageKey); } catch { /* Storage may be disabled. */ }
    return resolveLanguage(saved, navigator.languages);
  });
  const t = translations[language];
  const formats = dateFormats[language];
  const number = (value: number | null | undefined) => formatNumber(value, language);
  useEffect(() => {
    document.documentElement.lang = language;
    document.title = t.pageTitle;
    document.querySelector('meta[name="description"]')?.setAttribute('content', t.description);
    try { localStorage.setItem(languageStorageKey, language); } catch { /* Keep the choice for this visit. */ }
  }, [language, t]);
  const [metric, setMetric] = useState<Metric>('heart_rate');
  const [period, setPeriod] = useState<Period>('day');
  const [date, setDate] = useState(DateTime.local().toISODate()!);
  const [zone, setZone] = useState(zones[0]);
  const [revision, setRevision] = useState(0);
  const [summary, setSummary] = useState<Summary | null>(null);
  const [samples, setSamples] = useState<Sample[]>([]);
  const [ingestion, setIngestion] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<unknown>(null);
  const range = useMemo(() => {
    const selected = DateTime.fromISO(date, { zone });
    const start = selected.startOf(period);
    const end = start.plus(period === 'day' ? { days: 1 } : period === 'week' ? { weeks: 1 } : { months: 1 });
    return { start, end };
  }, [date, period, zone]);
  const from = range.start.toUTC().toISO()!;
  const to = range.end.toUTC().toISO()!;
  const refresh = () => { clearHistoryCache(); setRevision(value => value + 1); };

  useEffect(() => {
    const controller = new AbortController();
    setLoading(true); setError(null); setSummary(null); setSamples([]); setIngestion(null);
    const params = { metric, from, to, timezone: zone, bucket: period === 'day' ? 'hour' : 'day' };
    async function load() {
      try {
        const result = await loadHistory(params, period === 'day', controller.signal);
        if (!controller.signal.aborted) { setSummary(result.summary); setSamples(result.samples); setIngestion(result.summary.last_ingestion); }
      } catch (failure) {
        if (!controller.signal.aborted) setError(failure);
      } finally { if (!controller.signal.aborted) setLoading(false); }
    }
    // Let StrictMode finish its setup/cleanup probe before starting a request.
    queueMicrotask(() => { if (!controller.signal.aborted) void load(); });
    return () => controller.abort();
  }, [metric, period, from, to, zone, revision]);

  const errorMessage = error instanceof HistoryError
    ? error.status === 0 ? t.tooMany : t.errors[error.status] ?? t.statusError(error.status)
    : t.loadError;
  const points: Point[] = period === 'day'
    ? samples.map(sample => ({ time: sample.start, value: sample.value, detail: sample.source }))
    : (summary?.buckets ?? []).map((bucket: Bucket) => ({ time: bucket.start, value: bucket.average!, detail: t.bucketDetail(number(bucket.count), number(bucket.min), number(bucket.max)) }));
  const move = (direction: number) => setDate(range.start.plus(period === 'day' ? { days: direction } : period === 'week' ? { weeks: direction } : { months: direction }).toISODate()!);
  const stats = summary?.summary;
  return <main>
    <header><a className="brand" href="/">♡ <span>Beatavue</span></a><div className="header-actions"><span className="badge">{t.badge}</span><select aria-label={t.language} value={language} onChange={event => setLanguage(event.target.value as Language)}><option value="en" lang="en">English</option><option value="ja" lang="ja">日本語</option></select></div></header>
    <section className="intro"><p className="eyebrow">{t.eyebrow}</p><h1>{t.title}<br /><em>{t.titleEmphasis}</em></h1><p>{t.introduction}</p></section>
    <section className="panel" aria-label={t.controls}>
      <div className="controls"><div className="segments">{(['heart_rate', 'hrv_sdnn'] as Metric[]).map(value => <button key={value} aria-pressed={metric === value} onClick={() => setMetric(value)}>{t[value]}</button>)}</div><button className="refresh" onClick={refresh} disabled={loading}>↻ {t.refresh}</button></div>
      <div className="navigation"><div className="segments periods">{(['day', 'week', 'month'] as Period[]).map(value => <button key={value} aria-pressed={period === value} onClick={() => setPeriod(value)}>{t[value]}</button>)}</div><div className="date"><button aria-label={t.previous} onClick={() => move(-1)}>‹</button><input type="date" aria-label={t.selectedDate} value={date} max={DateTime.now().setZone(zone).toISODate()!} onChange={event => { if (event.target.value) setDate(event.target.value); }} /><button aria-label={t.next} disabled={range.end.toMillis() > Date.now()} onClick={() => move(1)}>›</button></div><select aria-label={t.timezone} value={zone} onChange={event => setZone(event.target.value)}>{zones.map(value => <option key={value}>{value}</option>)}</select></div>
      <div className="chart-heading"><div><p className="eyebrow">{range.start.setLocale(language).toFormat(formats.short)} – {range.end.minus({ days: 1 }).setLocale(language).toFormat(formats.rangeEnd)}</p><h2>{t[metric]} <small>{units[metric]}</small></h2></div><span>{period === 'day' ? t.actual : t.daily}</span></div>
      {loading ? <div className="empty" role="status">{t.loading}</div> : error ? <div className="empty" role="alert"><h2>{t.unavailable}</h2><p>{errorMessage}</p><button onClick={refresh}>{t.retry}</button></div> : <Chart points={points} start={range.start.toMillis()} end={range.end.toMillis()} zone={zone} unit={units[metric]} aggregated={period !== 'day'} language={language} />}
      <div className="stats">{[[t.samples, stats?.count], [t.minimum, stats?.min], [t.maximum, stats?.max], [t.average, stats?.average]].map(([label, value]) => <div key={label as string}><span>{label}</span><strong>{number(value as number | null | undefined)} <small>{label === t.samples ? '' : units[metric]}</small></strong></div>)}</div>
      <p className="note">{t.note}</p>
    </section>
    <section className="footnotes"><div><p className="eyebrow">{t.latest}</p><strong>{summary?.latest ? `${number(summary.latest.value)} ${units[metric]}` : t.noMeasurement}</strong><p>{summary?.latest ? DateTime.fromISO(summary.latest.start).setZone(zone).setLocale(language).toFormat(formats.latest) : t.choosePeriod}</p></div><div><p className="eyebrow">{t.ingestion}</p><strong>{ingestion ? DateTime.fromISO(ingestion).setZone(zone).setLocale(language).toFormat(formats.ingestion) : t.noUpload}</strong><p>{t.uploadNote}</p></div></section>
    <footer>{t.footer}</footer>
  </main>;
}

createRoot(document.getElementById('root')!).render(<React.StrictMode><App /></React.StrictMode>);
