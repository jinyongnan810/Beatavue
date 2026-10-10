export type Language = 'en' | 'ja';
export const languageStorageKey = 'beatavue.language';
export function resolveLanguage(saved: string | null, preferred: readonly string[]): Language {
  if (saved === 'en' || saved === 'ja') return saved;
  return preferred[0]?.toLowerCase().split('-')[0] === 'ja' ? 'ja' : 'en';
}

const en = {
  language: 'Language', badge: 'Personal health journal', eyebrow: 'A little closer to the rhythm',
  title: 'Heart history,', titleEmphasis: 'at a glance.',
  introduction: 'One person’s Apple Health measurements. Shared openly, with room for the gaps.',
  heart_rate: 'Heart rate', hrv_sdnn: 'HRV (SDNN)', controls: 'History controls', refresh: 'Refresh',
  day: 'day', week: 'week', month: 'month', previous: 'Previous period', next: 'Next period',
  selectedDate: 'Selected date', timezone: 'Display timezone', actual: 'Actual measurements', daily: 'Daily sample averages',
  loading: 'Loading published history…', unavailable: 'History is unavailable', retry: 'Try again',
  samples: 'Samples', minimum: 'Minimum', maximum: 'Maximum', average: 'Sample average',
  note: 'Averages give equal weight to available samples. Measurements are intermittent; gaps do not imply continuous recording. Overlapping sources are retained.',
  latest: 'Latest in this period', noMeasurement: 'No measurement', choosePeriod: 'Choose a period with published samples.',
  ingestion: 'Last server ingestion', noUpload: 'No upload yet', uploadNote: 'Recent device measurements may not have uploaded yet.',
  footer: 'Beatavue · Historical measurements, not medical guidance. HRV is SDNN in milliseconds. Live workout readings stay on the iPhone and Watch.',
  emptyTitle: 'No published measurements', emptyNote: 'Try another date. New device readings may still be waiting to upload.',
  inspect: 'Select a point to inspect its value and time.', sampleAverages: 'Sample averages', measuredSamples: 'Measured samples',
  chartLabel: (label: string, unit: string) => `${label} in ${unit}`,
  bucketDetail: (count: string, min: string, max: string) => `Average of ${count} available samples · min ${min} / max ${max}`,
  pageTitle: 'Beatavue · Heart history', description: 'Beatavue — a personal heart-rate and HRV history, published from Apple Health.',
  loadError: 'Could not load history.', tooMany: 'Too many samples to display.',
  errors: {
    400: 'This date range or timezone could not be queried.',
    409: 'Published data changed. Refresh to load the new dataset.',
    422: 'Too many measurements in this range. Select a shorter period.',
    429: 'The public API is busy. Please try again shortly.',
    503: 'Cloud data is temporarily unavailable. Please try again.',
  } as Record<number, string>,
  statusError: (status: number) => `Could not load history (${status}).`,
};
const ja: typeof en = {
  language: '言語', badge: '個人の健康記録', eyebrow: 'からだのリズムを、もっと身近に',
  title: '心拍の記録を、', titleEmphasis: 'ひと目で。',
  introduction: 'Appleヘルスケアに記録された、ある一人の測定データ。測定のない時間も含めて公開しています。',
  heart_rate: '心拍数', hrv_sdnn: '心拍変動（SDNN）', controls: '履歴の表示設定', refresh: '更新',
  day: '日', week: '週', month: '月', previous: '前の期間', next: '次の期間',
  selectedDate: '表示する日付', timezone: '表示タイムゾーン', actual: '実際の測定値', daily: '日ごとの測定値の平均',
  loading: '公開された履歴を読み込み中…', unavailable: '履歴を表示できません', retry: '再試行',
  samples: '測定数', minimum: '最小値', maximum: '最大値', average: '測定値の平均',
  note: '平均値は各測定値を同じ重みで計算しています。測定は断続的に行われ、空白の期間は連続測定を意味しません。複数のソースによる重複した測定値も含まれます。',
  latest: 'この期間の最新の測定値', noMeasurement: '測定値なし', choosePeriod: '測定値が公開されている期間を選んでください。',
  ingestion: 'サーバーへの最終取り込み', noUpload: 'アップロードなし', uploadNote: '端末の最新の測定値は、まだアップロードされていない場合があります。',
  footer: 'Beatavue · 過去の測定記録であり、医療上の助言ではありません。心拍変動はSDNNをミリ秒で表示しています。ワークアウト中のリアルタイム測定値はiPhoneとApple Watch内に保存されます。',
  emptyTitle: '公開された測定値がありません', emptyNote: '別の日付を選んでください。端末の新しい測定値は、アップロード待ちの場合があります。',
  inspect: '点を選ぶと、測定値と時刻を確認できます。', sampleAverages: '測定値の平均', measuredSamples: '測定値',
  chartLabel: (label, unit) => `${label}（単位：${unit}）`,
  bucketDetail: (count, min, max) => `${count}件の測定値の平均 · 最小 ${min} / 最大 ${max}`,
  pageTitle: 'Beatavue · 心拍の記録', description: 'Beatavue — Appleヘルスケアから公開する、個人の心拍数と心拍変動の記録。',
  loadError: '履歴を読み込めませんでした。', tooMany: '表示できる測定数を超えています。',
  errors: {
    400: 'この期間またはタイムゾーンのデータを取得できませんでした。',
    409: '公開データが変更されました。更新して最新のデータを読み込んでください。',
    422: 'この期間の測定数が多すぎます。より短い期間を選んでください。',
    429: '公開APIが混み合っています。少し待ってから再試行してください。',
    503: 'クラウドのデータを一時的に利用できません。再試行してください。',
  },
  statusError: status => `履歴を読み込めませんでした（${status}）。`,
};
export const translations = { en, ja };
export const dateFormats = {
  en: { short: 'MMM d', rangeEnd: 'MMM d, yyyy', timestamp: 'MMM d, HH:mm:ss ZZZZ', latest: 'MMM d, yyyy · HH:mm:ss ZZZZ', ingestion: 'MMM d, yyyy · HH:mm' },
  ja: { short: 'M月d日', rangeEnd: 'yyyy年M月d日', timestamp: 'M月d日 HH:mm:ss ZZZZ', latest: 'yyyy年M月d日 · HH:mm:ss ZZZZ', ingestion: 'yyyy年M月d日 · HH:mm' },
};
