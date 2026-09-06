export const MAX_SPEC_BYTES = 1_000_000;
export function validateFile(file) {
  if (!file) return 'Выберите YAML-файл.';
  if (!/\.ya?ml$/i.test(file.name)) return 'Нужен файл с расширением .yaml или .yml.';
  if (file.size > MAX_SPEC_BYTES) return 'Файл больше 1 МБ. Выберите спецификацию до 1 000 000 байт.';
  if (file.size === 0) return 'Файл пуст. Выберите спецификацию с содержимым.';
  return null;
}
export function formatBytes(size) { return size < 1000 ? `${size} Б` : `${(size / 1000).toLocaleString('ru-RU', { maximumFractionDigits: 1 })} КБ`; }
export function normalizeReport(report) {
  const cases = (Array.isArray(report?.cases) ? report.cases : []).map(item => {
    const explicit = ['passed', 'failed', 'skipped'].includes(item.status) ? item.status : null;
    const status = explicit || (item.ok === true ? 'passed' : item.ok === false ? 'failed' : 'skipped');
    return { ...item, status };
  });
  const passed = cases.filter(c => c.status === 'passed').length;
  const failed = cases.filter(c => c.status === 'failed').length;
  const skipped = cases.filter(c => c.status === 'skipped').length;
  const status = failed ? 'failed' : skipped || passed === 0 || ['partial', 'error', 'unavailable'].includes(report.status) ? 'partial' : 'passed';
  return { cases, passed, failed, skipped, status };
}
// Lightweight local highlighting. Tokens are inserted with textContent, never HTML.
export function tokensFor(text, name = '') {
  if (!/\.(rb|json)$/.test(name) || text.length > 300000) return [{ text, kind: null }];
  const regex = /("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|#[^\n]*|\b(?:class|module|def|end|require|require_relative|if|else|elsif|unless|return|case|when|rescue|do|true|false|nil|private|new|raise)\b|\b\d+(?:\.\d+)?\b)/g;
  const tokens = []; let last = 0;
  for (const match of text.matchAll(regex)) {
    if (match.index > last) tokens.push({ text: text.slice(last, match.index), kind: null });
    const value = match[0], kind = value.startsWith('#') ? 'comment' : /^["']/.test(value) ? 'string' : /^\d/.test(value) ? 'number' : 'keyword';
    tokens.push({ text: value, kind }); last = match.index + value.length;
  }
  if (last < text.length) tokens.push({ text: text.slice(last), kind: null });
  return tokens;
}
