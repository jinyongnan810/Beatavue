import { useEffect, useState } from 'react';
import { DateTime } from 'luxon';
import { isLive, subscribeLive, type LiveReading } from './live';
import { dateFormats, translations, type Language } from './i18n';

export function LiveHeartRate({ language, zone }: { language: Language; zone: string }) {
  const t = translations[language];
  const [reading, setReading] = useState<LiveReading | null>(null);
  const [connected, setConnected] = useState(false);
  const [now, setNow] = useState(Date.now());
  useEffect(() => {
    const unsubscribe = subscribeLive(setReading, setConnected, import.meta.env.VITE_LIVE_API_URL || "/v1/live");
    const clock = setInterval(() => setNow(Date.now()), 1000);
    return () => { unsubscribe(); clearInterval(clock); };
  }, []);
  const active = isLive(reading, connected, now);
  const status = !connected ? t.liveConnecting : active ? t.liveUpdating : t.liveInactive;
  return <section className={`panel live-panel${active ? ' is-live' : ''}`} aria-labelledby="live-title">
    <div><p className="eyebrow">{t.liveEyebrow}</p><h2 id="live-title">{t.liveTitle}</h2><p className="live-note">{t.liveNote}</p></div>
    <div className="live-reading"><div className="live-status" role="status"><span className="live-dot" />{status}</div>
      <strong>{active ? reading!.heart_rate!.toLocaleString(language, { maximumFractionDigits: 0 }) : '—'} <small>bpm</small></strong>
      {active && reading?.measured_at && <time dateTime={reading.measured_at}>{DateTime.fromISO(reading.measured_at).setZone(zone).setLocale(language).toFormat(dateFormats[language].timestamp)}</time>}
    </div>
  </section>;
}
