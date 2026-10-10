import assert from 'node:assert/strict';
import { test } from 'node:test';
import { resolveLanguage, translations } from '../src/i18n.ts';
import { DateTime } from 'luxon';
import { dateFormats } from '../src/i18n.ts';
import { get, HistoryError } from '../src/api.ts';

test('saved language overrides browser preference and unsupported preferences fall back to English', () => {
  assert.equal(resolveLanguage('en', ['ja-JP']), 'en');
  assert.equal(resolveLanguage('ja', ['en-US']), 'ja');
  assert.equal(resolveLanguage(null, ['ja-JP', 'en-US']), 'ja');
  assert.equal(resolveLanguage('invalid', ['JA']), 'ja');
  assert.equal(resolveLanguage(null, ['fr-FR', 'ja']), 'en');
  assert.equal(resolveLanguage(null, []), 'en');
});

test('Japanese dates and bucket descriptions use localized text', () => {
  const time = DateTime.fromISO('2026-10-10T12:30:00', { zone: 'Asia/Tokyo' }).setLocale('ja');
  assert.equal(time.toFormat(dateFormats.ja.rangeEnd), '2026年10月10日');
  assert.equal(translations.ja.bucketDetail('3', '60', '80'), '3件の測定値の平均 · 最小 60 / 最大 80');
});

test('API failures retain status for translation, including fallback statuses', async () => {
  const originalFetch = globalThis.fetch;
  try {
    for (const status of [400, 409, 422, 429, 503, 500]) {
      globalThis.fetch = async () => new Response(null, { status });
      await assert.rejects(get('/v1/samples', {}, new AbortController().signal), failure => {
        assert.ok(failure instanceof HistoryError);
        assert.equal(failure.status, status);
        const message = translations.ja.errors[failure.status] ?? translations.ja.statusError(failure.status);
        assert.match(message, /[ぁ-んァ-ン一-龯]/);
        return true;
      });
    }
  } finally { globalThis.fetch = originalFetch; }
});
