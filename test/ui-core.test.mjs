import test from 'node:test';
import assert from 'node:assert/strict';
import { validateFile, normalizeReport, tokensFor } from '../public/ui-core.mjs';

test('file restrictions match the backend byte limit', () => {
  assert.equal(validateFile({ name: 'api.YAML', size: 1000000 }), null);
  assert.ok(validateFile({ name: 'api.yaml', size: 1000001 }));
  assert.ok(validateFile({ name: 'api.json', size: 20 }));
  assert.ok(validateFile({ name: 'api.yaml', size: 0 }));
});
test('empty, skipped and mixed verification results are never false green', () => {
  assert.equal(normalizeReport({ cases: [] }).status, 'partial');
  assert.equal(normalizeReport({ cases: [{ ok: null }] }).status, 'partial');
  assert.equal(normalizeReport({ cases: [{ ok: true }, { ok: false }] }).status, 'failed');
  assert.equal(normalizeReport({ cases: [{ ok: true }] }).status, 'passed');
  assert.equal(normalizeReport({ status: 'error', cases: [{ ok: true }] }).status, 'partial');
  assert.equal(normalizeReport({ passed: 99, failed: 0, cases: [{ status: 'failed' }] }).failed, 1);
});
test('highlighting preserves exact source including HTML and quotes', () => {
  const source = '# <script>alert(1)</script>\nclass X\n  STATUS = "completed"\nend\n';
  assert.equal(tokensFor(source, 'service.rb').map(t => t.text).join(''), source);
  assert.equal(tokensFor('{"html":"<img onerror=1>"}', 'fixtures.json').map(t => t.text).join(''), '{"html":"<img onerror=1>"}');
});
