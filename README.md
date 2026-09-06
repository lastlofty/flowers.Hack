# PayBridge — генератор интеграций с платёжными провайдерами

[![Ruby tests](https://github.com/lastlofty/flowers.Hack/actions/workflows/test.yml/badge.svg)](https://github.com/lastlofty/flowers.Hack/actions/workflows/test.yml)
[![Lint](https://github.com/lastlofty/flowers.Hack/actions/workflows/lint.yml/badge.svg)](https://github.com/lastlofty/flowers.Hack/actions/workflows/lint.yml)

Кейс Space Payments: инструмент принимает OpenAPI 3.x-спецификацию провайдера
(`provider_api.yaml`) и генерирует готовую интеграцию под контракт
`Provider::BaseService` — Ruby-сервис, `INTEGRATION.md` и `fixtures.json`.

Только Ruby, открытый исходный код, без нейросетей.

## Состав репозитория

```
lib/paybridge/         # ядро: парсер, мапперы, IR, генераторы, verifier
lib/paybridge.rb       # фасад: generate / parse_only / load_overrides
app/                   # веб-бэкенд (Sinatra) поверх генератора (3-й участник)
public/                # простой UI загрузки спецификации
config/mapping.yml     # правила маппинга статусов/ошибок (без хардкода провайдера)
examples/              # 4 провайдера: novapay, bluepay, swiftpay, europay (+ overrides)
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

Результат — пять файлов в `./output/`: три основных артефакта
(`<provider>_service.rb`, `INTEGRATION.md`, `fixtures.json`) и два проверочных
(`<provider>_service_spec.rb`, `base_service.rb`).

Уточнения того, что нельзя достать из структуры OpenAPI (единица суммы, кодировка подписи,
условная обязательность полей) — через опциональный overrides-файл; чего в нём нет, ядро
выведет эвристикой и честно предупредит:

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

## Линт спецификации (Python-модуль)

Структурная проверка OpenAPI по стандарту (paths/операции/ответы, разрешимость
`$ref`, существование ссылок `security`) вынесена в отдельный **Python-модуль**
`tools/openapi_lint.py` (только stdlib). Многоязычность разрешена правилами; ядро
остаётся на Ruby, а линтер — вспомогательный слой и **опционален** (нет Python —
шаг пропускается, генерация работает).

```bash
ruby exe/integrate lint --spec examples/provider_api.yaml
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
