# PayBridge — генератор интеграций с платёжными провайдерами

[![Ruby tests](https://github.com/lastlofty/flowers.Hack/actions/workflows/test.yml/badge.svg)](https://github.com/lastlofty/flowers.Hack/actions/workflows/test.yml)
[![Lint](https://github.com/lastlofty/flowers.Hack/actions/workflows/lint.yml/badge.svg)](https://github.com/lastlofty/flowers.Hack/actions/workflows/lint.yml)

Кейс Space Payments: инструмент принимает OpenAPI 3.x-спецификацию провайдера
(`provider_api.yaml`) и генерирует готовую интеграцию под контракт
`Provider::BaseService` — Ruby-сервис, `INTEGRATION.md` и `fixtures.json`.

Только Ruby, открытый исходный код, без нейросетей.

## Чем мы отличаемся

Сгенерировать сервис умеют многие. Мы дополнительно **доказываем, что он работает,
и делаем это безопасно** — три вещи, которых нет ни у кого из участников:

1. **Verify прогнан на боевых спеках, а не только на своих примерах.** По каждому
   реальному провайдеру фикстуры воспроизводятся против сгенерированного сервиса
   (форма запроса, авторизация, статусы, callback, негативные проверки):
   **ЮKassa 3/3 · Adyen 3/3 · Klarna 3/3**, Stripe (594 метода) парсится за ~1 c.
   → [`examples/real/`](examples/real/README.md)
2. **Coverage-guided fuzzing генератора.** Greybox на `Coverage` из stdlib +
   harness под Trail of Bits **Ruzzy**/libFuzzer: 0 падений на 8000+ итерациях,
   регресс битых спек в `test/test_malformed_specs.rb`. → [`fuzz/`](fuzz/README.md)
3. **Безопасность самого кодогена.** `Paybridge::Safe` — весь вывод строится через
   экранированные литералы (нельзя внедрить Ruby через спеку); загрузка спеки по
   URL защищена от SSRF (запрет приватных/служебных адресов); `YAML.safe_load` с
   белым списком классов.

А ещё: детерминизм (`integrate diff` + golden-тесты байт-в-байт), артефакт
`<provider>_mapping.yml` «что инструмент понял» с провенансом (sha256 спеки),
экспорт Postman-коллекции, честные предупреждения и пометки «заполнить вручную»
вместо молчаливых догадок.

## Состав репозитория

```
lib/paybridge/         # ядро: парсер, мапперы, IR, генераторы, verifier
lib/paybridge.rb       # фасад: generate / parse_only / load_overrides
app/                   # веб-бэкенд (Sinatra) поверх генератора (3-й участник)
public/                # простой UI загрузки спецификации
config/mapping.yml     # правила маппинга статусов/ошибок (без хардкода провайдера)
examples/              # 4 синтетических провайдера (+ overrides) + manualpay
examples/real/         # боевые спеки: ЮKassa, Adyen, Klarna, Stripe (verify-доказано)
fuzz/                  # coverage-guided фаззинг (Ruzzy/libFuzzer harness)
test/                  # тесты (minitest + rack-test), test/unit/ — юниты
DECISIONS.md           # канон, допущения, точки расширения
ТЗ_PayBridge.md        # ТЗ ядра-генератора + CLI (тимлид)
ТЗ_напарник.md         # ТЗ: проверка/качество/документация/демо (2-й участник)
ТЗ_веб.md              # ТЗ веб-интерфейса (3-й участник)
```

## Бэкенд: запуск

```bash
bundle install
docker pull ruby:3.2-bookworm # ограниченная среда для verify
bundle exec rackup      # http://localhost:9292
```

Проверка и dry-run превью:

```bash
curl -X POST http://localhost:9292/api/integrations \
  -F "spec=@examples/provider_api.yaml" \
  -F "provider=novapay"

curl -X POST http://localhost:9292/api/validate \
  -F "spec=@examples/provider_api.yaml" \
  -F "provider=novapay"
```

UI — на `http://localhost:9292/`: можно предварительно проверить спецификацию,
сгенерировать интеграцию, увидеть результат `ruby -c`, скачать файлы и запустить
проверку fixtures.

`Paybridge.generate` использует реальное ядро из `lib/paybridge/`; CLI, веб-бэкенд
и тесты работают через один фасад без дублирования логики парсинга.

## Генератор: запуск (CLI)

```bash
ruby exe/integrate --spec examples/provider_api.yaml --provider novapay
```

Универсальность — тот же генератор на другом провайдере:

```bash
ruby exe/integrate --spec examples/bluepay_api.yaml --provider bluepay
```

Спека может передаваться по **http(s) URL**, а не только файлом:

```bash
ruby exe/integrate --spec https://example.com/provider_api.yaml --provider novapay
```

Загрузчик URL имеет таймауты, лимит 1 МБ, ограничение на redirect и защиту от
SSRF: локальные и служебные IP по умолчанию запрещены. Для изолированной локальной
разработки их можно явно разрешить через `PAYBRIDGE_ALLOW_PRIVATE_SPEC_URLS=1`.

Результат — восемь файлов в `./output/`:
- `<provider>_service.rb` — сервис по контракту `Provider::BaseService`;
- `INTEGRATION.md` — инструкция по подключению;
- `fixtures.json` — примеры запросов/ответов/уведомлений (контракт v3);
- `<provider>_service_spec.rb` — исполняемый тест;
- `<provider>_mapping.yml` — **«что инструмент понял»**: роли, авторизация,
  единица суммы, маппинги, поля для ручного заполнения и провенанс (sha256
  спеки) — главный файл для проверки глазами;
- `<provider>.postman_collection.json` — импортируемая коллекция Postman;
- `SAFETY.md` — **аудит платёжных рисков**: подпись webhook, авторизация,
  идемпотентность, TLS, единица суммы, поля для ручного заполнения (со строкой
  спеки) + итоговый вердикт готовности;
- `base_service.rb` — платформенный каркас (чтобы сервис запускался).

Уточнения того, что нельзя достать из структуры OpenAPI, — через опциональный
overrides-файл; чего в нём нет, ядро выведет эвристикой и честно предупредит:

| Ключ overrides | Для чего |
| --- | --- |
| `amount_unit` | `minor`/`major` — единица суммы |
| `signature_encoding` | `hex`/`base64` — кодировка подписи webhook |
| `required_if` | условная обязательность полей по способу |
| `create_endpoint` / `status_endpoint` | ручной выбор метода (`"POST /v1/payment_intents"`) на крупных/неоднозначных спеках |
| `security_scheme` | форсировать именованную схему авторизации (напр. `ApiKeyAuth` у Adyen вместо HTTP Basic) |

```bash
ruby exe/integrate --spec examples/provider_api.yaml --provider novapay --overrides examples/overrides.novapay.yml
```

## Предпросмотр без генерации (validate)

Показать, что распознал парсер (методы, авторизация, статусы, ошибки, webhook,
предупреждения), не создавая файлов:

```bash
ruby exe/integrate validate --spec examples/europay_api.yaml --provider europay
```

## Проверка сгенерированной интеграции

`verify` прогоняет `fixtures.json` против сгенерированного сервиса через мок-клиент:
вызывает `create_request` / `fetch_status` / `process_callback` (с реальной проверкой
HMAC-подписи) и сверяет с ожиданиями. Доказывает, что интеграция работает, а не только
компилируется.

```bash
ruby exe/integrate --spec examples/provider_api.yaml --provider novapay
ruby exe/integrate verify --dir output
```
```
  OK   create_request.response_201
  OK   callback.completed
  ...
  7 passed, 0 failed
```

## Детерминизм (diff)

`diff` перегенерирует интеграцию в память и сверяет **байт-в-байт** с уже
сгенерированным каталогом. Ненулевой код при расхождении — детерминизм в CI без
внешних инструментов (генерация выводит LF на всех платформах).

```bash
ruby exe/integrate --spec examples/provider_api.yaml --provider novapay --output output
ruby exe/integrate diff --spec examples/provider_api.yaml --provider novapay --dir output
# diff: без изменений — генерация детерминирована и совпадает с output
```

`--strict` при генерации завершает работу ненулевым кодом, если остались поля для
ручного заполнения (см. `<provider>_mapping.yml`).

## Docker

Ядро-генератор использует только stdlib — образ минимальный, без bundle:

```bash
docker build -t paybridge .
docker run --rm -v "$PWD:/work" paybridge \
  --spec /work/examples/provider_api.yaml --provider novapay --output /work/output
```

## Самопроверка вывода (selftest)

`selftest` запускает **сгенерированный** `<provider>_service_spec.rb` (реальный
артефакт из вывода) в отдельном процессе — доказывает, что вывод не просто
компилируется, а его собственные контрактные тесты зелёные.

```bash
ruby exe/integrate --spec examples/provider_api.yaml --provider novapay --output output
ruby exe/integrate selftest --dir output
# selftest: зелёный — 15 runs, 85 assertions, 0 failures, 0 errors, 0 skips
```

## HTML-инструкция (docs)

`docs` собирает самодостаточную HTML-инструкцию по интеграции (что распознано,
авторизация, методы, маппинги, webhook, поля «заполнить вручную», диагностика с
уровнями, провенанс) — открыть в браузере или отдать заказчику.

```bash
ruby exe/integrate docs --spec examples/provider_api.yaml --provider novapay --output docs
# HTML-инструкция: docs/novapay_integration.html
```

## Линт спецификации (Python-модуль)

Структурная проверка OpenAPI по стандарту (paths/операции/ответы, разрешимость
`$ref`, существование ссылок `security`) вынесена в отдельный **Python-модуль**
`tools/openapi_lint.py` (только stdlib). Многоязычность разрешена правилами; ядро
остаётся на Ruby, а линтер — вспомогательный слой и **опционален** (нет Python —
шаг пропускается, генерация работает).

```bash
ruby exe/integrate lint --spec examples/provider_api.yaml
```

## Демо одной командой + HTML-отчёт

`rake demo` прогоняет весь конвейер (parse → generate → `ruby -c` → verify) по всем
провайдерам (включая реальную ЮKassa) и печатает сводную таблицу + пишет
самодостаточный `demo_report.html` (что распознано, маппинги, артефакты, verify,
честные предупреждения) — одна страница для наглядной демонстрации.

```bash
rake demo
```

## Живой e2e (по реальному HTTP)

Сгенерированный сервис прогоняется против мок-провайдера (WEBrick, поднят из спеки)
РЕАЛЬНЫМ `net/http`: `create` (POST с авторизацией и Idempotency-Key, сумма в
копейках в теле) → `fetch_status` (GET) → `webhook` (подпись по сырому телу; подделка
тела отклоняется). Доказывает, что интеграция работает целиком по проводам, а не
только через мок-клиент.

```bash
ruby tools/e2e_demo.rb                          # NovaPay
ruby tools/e2e_demo.rb examples/real/yookassa.yaml yookassa
```

## Тесты

```bash
rake test
```

Или по отдельности:

```bash
ruby -Ilib -Itest test/test_spec_parser.rb
ruby -Ilib -Itest test/test_generators.rb
ruby -Ilib -Itest test/test_universality.rb
ruby -Ilib -Itest test/test_api.rb
```

## API

| Метод | Путь | Назначение |
|-------|------|-----------|
| POST | `/api/validate` | Dry-run: разобрать спецификацию без файлов и записи в storage |
| POST | `/api/integrations` | Загрузить спецификацию, сгенерировать интеграцию |
| GET | `/api/integrations` | История с пагинацией |
| GET | `/api/integrations/:id` | Метаданные + файлы + последний verify |
| GET | `/api/integrations/:id/model` | Сохранённая распознанная модель |
| GET | `/api/integrations/:id/files/:name` | Скачать один файл |
| GET | `/api/integrations/:id/archive` | Скачать zip |
| POST | `/api/integrations/:id/verify` | Прогнать fixtures против сгенерированного сервиса |
| GET | `/api/health` | Живость и доступность безопасного verify |

Ответ создания содержит `valid` и `syntax_error`: бэкенд автоматически запускает
`ruby -c` для сгенерированного сервиса. Ошибка синтаксиса остаётся видимым результатом,
но не роняет API.

HTTP `verify` выполняется только в одноразовом Docker-контейнере без сети и доступа
к секретам/общему storage. Если изоляция недоступна, API отвечает 503 и не включает
локальный fallback. Подробности: [безопасный запуск](docs/verification-sandbox.md) и
[контракт Web API](docs/web-api.md).
