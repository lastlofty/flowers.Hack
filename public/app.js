import { validateFile, formatBytes, normalizeReport, tokensFor } from './ui-core.mjs';

const $ = id => document.getElementById(id);
const state = { file: null, model: null, generation: null, report: null, stage: 0,
  tab: 'methods', endpoint: 0, activeFile: null, fileText: null, fileLoading: false,
  fileError: '', busy: false, health: null, revision: 0, operation: null, fileRequest: null };
const headings = [
  ['Начните со спецификации', 'Загрузите OpenAPI-файл вашего платёжного провайдера.'],
  ['Посмотрите, что распознано', 'Методы, авторизация и сопоставления из вашей спецификации.'],
  ['Ваша интеграция в исходниках', 'Просмотрите код и материалы перед подключением к платформе.'],
  ['Проверьте результат', 'Синтаксис и сценарии проверяются независимо.']
];
const roles = { create: 'Создание операции', status: 'Получение статуса', cancel: 'Отмена', webhook: 'Webhook', other: 'Другой метод' };
const methods = { create: 'create_request()', status: 'fetch_status()', webhook: 'process_callback()' };

function el(tag, text, className) {
  const node = document.createElement(tag);
  if (text !== undefined && text !== null) node.textContent = String(text);
  if (className) node.className = className;
  return node;
}
function clearError() { $('error-banner').hidden = true; }
function showError(message, title = 'Не удалось выполнить действие') {
  $('error-title').textContent = title;
  $('error-message').textContent = message;
  $('error-banner').hidden = false;
}
let toastTimer;
function notify(message) {
  clearTimeout(toastTimer); $('toast').textContent = message; $('toast').hidden = false;
  toastTimer = setTimeout(() => { $('toast').hidden = true; }, 5000);
}
function setBusy(value, label = '') {
  state.busy = value; document.body.classList.toggle('is-busy', value);
  $('busy-banner').hidden = !value; $('busy-label').textContent = label;
  $('source-form').setAttribute('aria-busy', String(value));
  $('provider').disabled = value; $('spec-file').disabled = value;
  renderControls();
}
function invalidate() {
  state.revision++; state.operation?.abort(); state.fileRequest?.abort();
  Object.assign(state, { model: null, generation: null, report: null, stage: 0,
    endpoint: 0, activeFile: null, fileText: null, fileLoading: false, fileError: '' });
  clearError(); render();
}
function chooseFile(file) {
  if (state.busy) return;
  invalidate(); state.file = null;
  const error = validateFile(file);
  if (error) { $('spec-file').value = ''; showError(error, 'Проверьте файл'); }
  else state.file = file;
  render();
}

async function request(path, { method = 'GET', body, signal, timeout = 30000, text = false } = {}) {
  const controller = new AbortController();
  let timedOut = false;
  const abort = () => controller.abort();
  if (signal?.aborted) controller.abort();
  signal?.addEventListener('abort', abort, { once: true });
  const timer = setTimeout(() => { timedOut = true; controller.abort(); }, timeout);
  try {
    const response = await fetch(path, { method, body, signal: controller.signal, headers: { Accept: text ? 'text/plain' : 'application/json' }, cache: 'no-store' });
    const raw = await response.text();
    let data;
    if (!text || !response.ok) { try { data = JSON.parse(raw); } catch { data = null; } }
    if (!response.ok) {
      const message = response.status >= 500 && response.status !== 503 && response.status !== 504
        ? 'Сервер не смог обработать запрос. Проверьте спецификацию или повторите позже.'
        : data?.error?.message || `Сервер вернул ошибку HTTP ${response.status}.`;
      const error = new Error(message); error.code = data?.error?.code; error.status = response.status; throw error;
    }
    if (!text && (!data || typeof data !== 'object' || Array.isArray(data))) throw new Error('Сервер вернул ответ в неожиданном формате.');
    return text ? raw : data;
  } catch (error) {
    if (timedOut) throw new Error('Время ожидания истекло. Сервер мог продолжить обработку; результат этого запроса не получен.');
    if (error.name === 'TypeError') throw new Error('Нет связи с сервером. Проверьте подключение и запуск PayBridge.');
    throw error;
  } finally { clearTimeout(timer); signal?.removeEventListener('abort', abort); }
}
async function health() {
  $('health-button').disabled = true;
  try {
    const result = await request('/api/health', { timeout: 12000 });
    if (result.status !== 'ok') throw new Error('unavailable');
    state.health = result;
    $('health-dot').className = 'connection-dot online'; $('health-text').textContent = 'Сервер доступен';
  } catch {
    state.health = null; $('health-dot').className = 'connection-dot offline'; $('health-text').textContent = 'Нет связи · повторить';
  } finally { $('health-button').disabled = false; renderVerification(); renderControls(); }
}
function upload() { const data = new FormData(); data.append('spec', state.file); data.append('provider', $('provider').value.trim()); return data; }
async function analyze(event) {
  event?.preventDefault();
  if (state.busy) return;
  if (!state.file) { showError('Выберите YAML-файл со спецификацией.', 'Добавьте файл'); return; }
  if (!$('source-form').reportValidity()) return;
  invalidate();
  const revision = state.revision, controller = new AbortController(); state.operation = controller;
  setBusy(true, 'Разбираем спецификацию…');
  try {
    const model = await request('/api/validate', { method: 'POST', body: upload(), signal: controller.signal });
    if (revision !== state.revision) return;
    if (!Array.isArray(model.endpoints)) throw new Error('В ответе сервера отсутствует список методов API.');
    state.model = model; state.stage = 1; render();
  } catch (error) { if (error.name !== 'AbortError' && revision === state.revision) showError(error.message, 'Спецификация не разобрана'); }
  finally { if (revision === state.revision) setBusy(false); }
}
async function generate() {
  if (state.busy || !state.model || state.generation) return;
  const revision = state.revision, controller = new AbortController(); state.operation = controller;
  clearError(); setBusy(true, 'Генерируем файлы и проверяем Ruby-синтаксис…');
  try {
    const data = await request('/api/integrations', { method: 'POST', body: upload(), signal: controller.signal });
    if (revision !== state.revision) return;
    if (typeof data.id !== 'string' || !Array.isArray(data.files) || data.files.some(f => typeof f !== 'string')) throw new Error('Сервер не вернул корректный список файлов интеграции.');
    state.generation = data; state.report = data.verification?.cases ? normalizeReport(data.verification) : null; state.stage = 2;
    render();
    const first = data.files.find(f => f.endsWith('_service.rb')) || data.files[0];
    if (first) await loadFile(first);
  } catch (error) { if (error.name !== 'AbortError' && revision === state.revision) showError(error.message, 'Не удалось создать интеграцию'); }
  finally { if (revision === state.revision) setBusy(false); }
}
function fileURL(name) { return `/api/integrations/${encodeURIComponent(state.generation.id)}/files/${encodeURIComponent(name)}`; }
async function loadFile(name) {
  if (!state.generation?.files.includes(name)) return;
  state.fileRequest?.abort(); const controller = new AbortController(); state.fileRequest = controller;
  const revision = state.revision, id = state.generation.id;
  Object.assign(state, { activeFile: name, fileText: null, fileLoading: true, fileError: '' }); renderFiles();
  try {
    const text = await request(fileURL(name), { signal: controller.signal, text: true });
    if (revision === state.revision && state.generation?.id === id && state.activeFile === name && state.fileRequest === controller) state.fileText = text;
  } catch (error) {
    if (error.name !== 'AbortError' && revision === state.revision && state.activeFile === name && state.fileRequest === controller) state.fileError = error.message;
  } finally {
    if (revision === state.revision && state.activeFile === name && state.fileRequest === controller) { state.fileLoading = false; renderFiles(); }
  }
}
async function verify() {
  if (state.busy || !state.generation || state.health?.verification_available !== true || state.generation.valid !== true) return;
  const revision = state.revision, controller = new AbortController(); state.operation = controller;
  clearError(); setBusy(true, 'Проверяем интеграцию…');
  try {
    const result = await request(`/api/integrations/${encodeURIComponent(state.generation.id)}/verify`, { method: 'POST', signal: controller.signal, timeout: 45000 });
    if (revision !== state.revision) return;
    if (!Array.isArray(result.cases)) throw new Error('Сервер не вернул сценарии проверки.');
    state.report = normalizeReport(result); renderVerification();
  } catch (error) {
    if (error.name !== 'AbortError' && revision === state.revision) {
      state.report = null;
      if (error.code === 'verification_unavailable' && state.health) state.health.verification_available = false;
      renderVerification(); showError(error.message, 'Проверка не выполнена');
    }
  } finally { if (revision === state.revision) setBusy(false); }
}
function table(headers, rows) {
  const wrapper = el('div', null, 'table-wrap'), t = el('table', null, 'data-table');
  const head = el('thead'), tr = el('tr'); headers.forEach(label => { const cell = el('th', label); cell.scope = 'col'; tr.append(cell); }); head.append(tr); t.append(head);
  const body = el('tbody'); rows.forEach(row => { const tr = el('tr'); row.forEach(value => tr.append(el('td', value ?? 'Не указано'))); body.append(tr); }); t.append(body); wrapper.append(t); return wrapper;
}
function note(text) { return el('div', text, 'inline-note'); }
function empty(text) { return el('p', text, 'empty-content'); }
function renderControls() {
  document.querySelectorAll('.endpoint-button').forEach(button => { button.disabled = state.busy; });
  document.querySelectorAll('[data-stage]').forEach(button => {
    const stage = Number(button.dataset.stage), available = stage === 0 || (stage === 1 && state.model) || (stage >= 2 && state.generation);
    button.disabled = state.busy || !available;
    if (stage === state.stage) button.setAttribute('aria-current', 'step'); else button.removeAttribute('aria-current');
    button.classList.toggle('completed', stage === 0 ? !!state.model : stage === 1 ? !!state.generation : false);
  });
  $('analyze-button').disabled = state.busy;
  $('generate-button').disabled = state.busy || !state.model?.endpoints.some(e => e.role === 'create');
  $('review-button').disabled = state.busy;
  $('verify-button').disabled = state.busy || state.health?.verification_available !== true || state.generation?.valid !== true;
}
function renderSource() {
  $('selected-file').hidden = !state.file;
  $('file-name').textContent = state.file?.name || ''; $('file-size').textContent = state.file ? formatBytes(state.file.size) : '';
  $('drop-title').textContent = state.file ? 'Заменить спецификацию' : 'Перетащите YAML';
  $('drop-caption').textContent = state.file ? 'Новый файл сбросит результат' : 'или выберите файл';
  const summary = $('source-summary'); summary.replaceChildren(); summary.hidden = !state.model;
  if (state.model) summary.append(el('strong', state.model.title || 'API без названия'), el('span', `Версия ${state.model.version || 'не указана'}`));
  $('endpoint-section').hidden = !state.model || state.stage >= 2;
  $('file-section').hidden = !state.generation || state.stage < 2;
  const list = $('endpoint-list'); list.replaceChildren();
  $('endpoint-count').textContent = state.model?.endpoints.length || '';
  state.model?.endpoints.forEach((endpoint, index) => {
    const button = el('button', null, 'endpoint-button'); button.type = 'button'; button.disabled = state.busy;
    button.setAttribute('aria-pressed', String(index === state.endpoint));
    button.append(el('span', endpoint.method, `method ${endpoint.method === 'GET' ? 'get' : endpoint.method === 'POST' ? '' : 'other'}`), el('span', endpoint.path, 'endpoint-path'), el('small', roles[endpoint.role] || 'Неизвестная роль'));
    button.onclick = () => { state.endpoint = index; state.tab = 'methods'; state.stage = 1; render(); }; list.append(button);
  });
}
function renderModel() {
  const container = $('model-content'); container.replaceChildren(); if (!state.model) return;
  const model = state.model;
  document.querySelectorAll('[data-tab]').forEach(button => button.setAttribute('aria-selected', String(button.dataset.tab === state.tab)));
  container.setAttribute('aria-labelledby', `tab-${state.tab}`);
  if (state.tab === 'methods') {
    const endpoint = model.endpoints[state.endpoint];
    if (!endpoint) { container.append(empty('В спецификации не распознаны методы.')); return; }
    const head = el('div', null, 'mapping-header'), left = el('div'), right = el('div');
    left.append(el('small', 'API ПРОВАЙДЕРА'), el('strong', `${endpoint.method} ${endpoint.path}`));
    right.append(el('small', 'МЕТОД СЕРВИСА'), el('strong', methods[endpoint.role] || 'Не генерируется'));
    head.append(left, el('span', '→', 'mapping-arrow'), right); container.append(head);
    container.append(table(['Параметр', 'Распознано'], [['Назначение', roles[endpoint.role] || endpoint.role], ['Адрес API', model.base_url], ['Идемпотентность', model.idempotency_header || 'Не найдена']]));
    if (!methods[endpoint.role]) container.append(note('Этот endpoint найден в спецификации, но текущий генератор не создаёт для него отдельный метод.'));
    container.append(note('Сопоставления полей запроса пока не возвращаются API. После генерации их можно посмотреть в исходном Ruby-сервисе.'));
  } else if (state.tab === 'statuses') {
    const statuses = Object.entries(model.status_map || {});
    container.append(el('h2', 'Статусы операций'));
    container.append(statuses.length ? table(['Провайдер', 'PayBridge'], statuses) : empty('Маппинг статусов не найден. Проверьте предупреждения.'));
    const errors = Object.entries(model.error_map || {});
    if (errors.length) { container.append(el('div', null, 'panel-divider'), el('h3', 'HTTP-ошибки'), table(['HTTP', 'Внутренний код'], errors)); }
  } else if (state.tab === 'auth') {
    container.append(el('h2', 'Авторизация и подключение'));
    if (model.auth) container.append(table(['Параметр', 'Значение'], [['Тип схемы', model.auth.type], ['Заголовок / параметр', model.auth.header], ['Поле credentials', model.auth.credentials_field], ['Адрес API', model.base_url]]));
    else container.append(empty('Схема авторизации не распознана.'));
    container.append(note('Ключи и секреты здесь не запрашиваются. Они задаются при подключении сгенерированного сервиса.'));
  } else {
    const hook = model.webhook; container.append(el('h2', 'Webhook'));
    if (!hook) { container.append(empty('Webhook не распознан в спецификации.')); return; }
    container.append(table(['Параметр', 'Значение'], [['Путь', hook.path], ['Заголовок подписи', hook.signature_header || 'Не найден'], ['Алгоритм HMAC', hook.signature_alg || 'Не указан']]));
    container.append(el('div', null, 'panel-divider'), el('h3', 'События'));
    const events = Array.isArray(hook.events) ? hook.events : []; const list = el('ul'); events.forEach(event => list.append(el('li', event)));
    container.append(events.length ? list : empty('События не распознаны.'));
  }
}
function renderFiles() {
  const list = $('file-list'); list.replaceChildren();
  state.generation?.files.forEach(name => { const button = el('button', name, 'file-button'); button.type = 'button'; button.setAttribute('aria-pressed', String(state.activeFile === name)); button.onclick = () => { state.stage = 2; render(); loadFile(name); }; list.append(button); });
  $('active-file-name').textContent = state.activeFile || 'Выберите файл';
  $('file-feedback').replaceChildren();
  if (state.fileLoading) $('file-feedback').textContent = 'Загружаем содержимое…';
  else if (state.fileError) {
    $('file-feedback').append(el('p', state.fileError)); const retry = el('button', 'Повторить', 'button small'); retry.type = 'button'; retry.onclick = () => loadFile(state.activeFile); $('file-feedback').append(retry);
  }
  $('copy-file').disabled = state.fileText === null || state.fileLoading;
  const link = $('download-file'); link.hidden = !state.activeFile || !state.generation;
  if (!link.hidden) { link.href = fileURL(state.activeFile); link.download = state.activeFile; } else link.removeAttribute('href');
  const code = $('file-code'); code.replaceChildren();
  if (state.fileText !== null) {
    const fragment = document.createDocumentFragment();
    tokensFor(state.fileText, state.activeFile).forEach(token => fragment.append(token.kind ? el('span', token.text, `token-${token.kind}`) : document.createTextNode(token.text)));
    code.append(fragment);
  }
}
function checkRow(title, description, status) {
  const row = el('div', null, 'check-row'), text = el('div'); text.append(el('strong', title), el('p', description));
  row.append(el('span', status === 'good' ? '✓' : status === 'bad' ? '×' : '○', `check-symbol ${status || ''}`), text); return row;
}
function renderVerification() {
  const summary = $('verification-summary'), report = $('verification-report'); summary.replaceChildren(); report.replaceChildren();
  if (!state.generation) return;
  const gen = state.generation;
  summary.append(checkRow('Файлы созданы', `Получено файлов: ${gen.files.length}`, 'good'));
  summary.append(checkRow('Ruby-синтаксис', gen.valid === true ? 'Сервис прошёл ruby -c.' : gen.valid === false ? gen.syntax_error || 'Синтаксическая проверка не пройдена.' : 'Сервер не передал результат проверки.', gen.valid === true ? 'good' : gen.valid === false ? 'bad' : ''));
  const r = state.report;
  const reportDescription = r ? r.status === 'passed' ? 'Все возвращённые сценарии прошли. Это не гарантия полной совместимости с провайдером.' : r.status === 'failed' ? 'Некоторые сценарии не прошли. Откройте подробности.' : 'Проверка неполная: часть сценариев пропущена или не выполнена.' : 'Проверка сценариев ещё не выполнялась.';
  summary.append(checkRow('Сценарии интеграции', reportDescription, r?.status === 'passed' ? 'good' : r?.status === 'failed' ? 'bad' : ''));
  summary.append(note('Проверка выполняет сгенерированный сервис в изолированном контейнере на данных fixtures. Ответы платёжного API задаются тестовыми сценариями; реальные платежи не отправляются.'));
  if (r) {
    const counts = el('div', null, 'check-counts'); [[r.passed, 'успешно'], [r.failed, 'с ошибкой'], [r.skipped, 'пропущено']].forEach(([n, label]) => { const item = el('span'); item.append(el('b', n), document.createTextNode(label)); counts.append(item); }); report.append(counts);
    r.cases.forEach(c => { const details = el('details', null, 'case'), heading = el('summary'); heading.append(el('span', c.status === 'passed' ? '✓' : c.status === 'failed' ? '×' : '○', `case-status ${c.status === 'passed' ? 'good' : c.status === 'failed' ? 'bad' : ''}`), document.createTextNode(String(c.name || 'Сценарий'))); details.append(heading, el('p', c.detail || 'Подробности не переданы')); report.append(details); });
  }
  const unavailable = $('verify-unavailable'); unavailable.hidden = state.health?.verification_available === true;
  unavailable.textContent = state.health ? state.health.verification_reason || 'Безопасная проверка пока не подключена. Файлы можно посмотреть и скачать.' : 'Доступность проверки не подтверждена. Обновите статус сервера.';
  renderControls();
}
function renderWarnings() {
  const warnings = state.generation?.warnings ?? state.model?.warnings ?? [];
  const items = Array.isArray(warnings) ? warnings : [];
  $('warnings-panel').hidden = !items.length || state.stage === 0; $('warning-count').textContent = items.length;
  $('warnings-list').replaceChildren(...items.map(w => el('li', typeof w === 'string' ? w : JSON.stringify(w))));
}
function render() {
  const stage = state.stage; $('page-title').textContent = headings[stage][0]; $('page-description').textContent = headings[stage][1];
  $('breadcrumb-provider').textContent = state.model?.provider || 'Новая интеграция';
  $('provider-badge').textContent = state.model?.provider || ''; $('provider-badge').hidden = !state.model;
  ['welcome-view', 'model-view', 'files-view', 'verification-view'].forEach((id, index) => { $(id).hidden = index !== stage; });
  $('action-footer').hidden = stage === 0; $('generate-button').hidden = !!state.generation; $('review-button').hidden = !state.generation || stage === 3;
  const archive = $('download-archive'); archive.hidden = !state.generation;
  if (state.generation) { archive.href = `/api/integrations/${encodeURIComponent(state.generation.id)}/archive`; archive.download = `integration_${state.generation.provider}.zip`; }
  else archive.removeAttribute('href');
  $('footer-description').textContent = state.generation ? `Интеграция ${state.generation.id}` : state.model?.endpoints.some(e => e.role === 'create') ? 'Изучите предупреждения перед генерацией.' : 'Не найден метод создания операции. Генерация недоступна.';
  renderSource(); renderModel(); renderFiles(); renderVerification(); renderWarnings(); renderControls();
}

$('source-form').addEventListener('submit', analyze);
$('spec-file').addEventListener('change', event => { if (event.target.files[0]) chooseFile(event.target.files[0]); });
$('provider').addEventListener('input', () => { if (!state.busy) invalidate(); });
const drop = $('drop-zone'); let dragDepth = 0;
drop.addEventListener('dragenter', event => { event.preventDefault(); if (!state.busy) { dragDepth++; drop.classList.add('dragover'); } });
drop.addEventListener('dragover', event => { event.preventDefault(); event.dataTransfer.dropEffect = state.busy ? 'none' : 'copy'; });
drop.addEventListener('dragleave', () => { dragDepth = Math.max(0, dragDepth - 1); if (!dragDepth) drop.classList.remove('dragover'); });
drop.addEventListener('drop', event => { event.preventDefault(); dragDepth = 0; drop.classList.remove('dragover'); if (state.busy) return; if (event.dataTransfer.files.length !== 1) { showError('Перетащите один YAML-файл.'); return; } $('spec-file').value = ''; chooseFile(event.dataTransfer.files[0]); });
document.addEventListener('dragover', event => { if (event.dataTransfer?.types.includes('Files')) event.preventDefault(); });
document.addEventListener('drop', event => { if (event.dataTransfer?.files.length) event.preventDefault(); });
$('generate-button').onclick = generate; $('review-button').onclick = () => { state.stage = 3; render(); };
$('verify-button').onclick = verify; $('health-button').onclick = health; $('dismiss-error').onclick = clearError;
document.querySelectorAll('[data-stage]').forEach(button => { button.onclick = () => { if (button.disabled) return; state.stage = Number(button.dataset.stage); render(); }; });
const tabButtons = [...document.querySelectorAll('[data-tab]')];
tabButtons.forEach((button, index) => {
  button.onclick = () => { state.tab = button.dataset.tab; renderModel(); };
  button.onkeydown = event => { let next; if (event.key === 'ArrowRight') next = (index + 1) % tabButtons.length; else if (event.key === 'ArrowLeft') next = (index - 1 + tabButtons.length) % tabButtons.length; else if (event.key === 'Home') next = 0; else if (event.key === 'End') next = tabButtons.length - 1; if (next !== undefined) { event.preventDefault(); tabButtons[next].click(); tabButtons[next].focus(); } };
});
$('copy-file').onclick = async () => {
  if (state.fileText === null) return;
  try { await navigator.clipboard.writeText(state.fileText); notify('Содержимое файла скопировано.'); }
  catch { const selection = window.getSelection(), range = document.createRange(); range.selectNodeContents($('file-code')); selection.removeAllRanges(); selection.addRange(range); notify('Автокопирование недоступно. Текст выделен — нажмите Ctrl+C или ⌘C.'); }
};
render(); health();
