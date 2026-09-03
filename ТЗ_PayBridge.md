# ТЗ: PayBridge — генератор интеграций с платёжными провайдерами

**Кейс:** Space Payments — «Генератор интеграций с платёжными провайдерами»
**Стек:** только Ruby (весь код проекта — Ruby)
**Ограничения кейса:** запрещены нейросети внутри проекта, проприетарные технологии и решения с закрытым исходным кодом. За нарушение — дисквалификация.

---

## 1. Цель

Инструмент, который принимает OpenAPI-спецификацию провайдера (`provider_api.yaml`) и автоматически генерирует готовую интеграцию под контракт `Provider::BaseService`. Сейчас разработчик пишет такой сервис вручную 2–5 дней; задача — свести это к одному запуску.

Разбор спецификации — **детерминированный** (парсинг YAML + шаблоны), без нейросетей.

---

## 2. Вход / выход

**Вход:** файл OpenAPI 3.0 (`provider_api.yaml`).

**Запуск:**
```bash
./integrate --spec provider_api.yaml --provider novapay
```

**Выход** — 3 файла в `./output/`, за один прогон:

| Файл | Назначение |
|------|-----------|
| `<provider>_service.rb` | Ruby-сервис по контракту `Provider::BaseService` |
| `INTEGRATION.md` | Документация: авторизация, методы, маппинг статусов/ошибок, webhook |
| `fixtures.json` | Тестовые фикстуры (request / response / callback) |

> Флаг `--lang` не реализуем: по правилам код должен быть на Ruby, мультиязычная генерация — не в скоупе. Генерируем только Ruby.

---

## 3. Архитектура

Принцип: **разбор спеки → промежуточная модель (IR) → рендер шаблонов**. Ядро генератора не знает про NovaPay — вся специфика провайдера живёт в YAML и IR.

```
lib/paybridge/
  cli.rb                 # optparse: --spec, --provider, --output
  spec_parser.rb         # YAML → IR
  ir/
    spec.rb              # endpoints, auth, schemas, webhooks
    endpoint.rb
    auth.rb
    webhook.rb
  mappers/
    status_mapper.rb     # provider status → Space Payments status
    error_mapper.rb      # HTTP code → действие
    field_mapper.rb      # поля запроса/ответа
  generators/
    service_generator.rb    # → *_service.rb (ERB)
    docs_generator.rb       # → INTEGRATION.md (ERB)
    fixtures_generator.rb    # → fixtures.json
  templates/
    service.rb.erb
    integration.md.erb
  report.rb              # предупреждения о неподдержанных элементах
config/
  mapping.yml            # правила маппинга статусов/ошибок (переопределяемые)
exe/integrate            # точка входа CLI
```

**Поток данных:** `CLI → SpecParser → IR → [ServiceGenerator, DocsGenerator, FixturesGenerator] → файлы + report`.

**Зависимости (только stdlib и открытые гемы):**
- Парсинг: `psych` (YAML, stdlib).
- Шаблоны: `erb` (stdlib).
- CLI: `optparse` (stdlib).
- HTTP в генераторе: `net/http` (stdlib). В *сгенерированном* сервисе допустим `faraday`.
- Тесты: RSpec или Minitest.
- `Gemfile` + `.ruby-version` (например Ruby 3.2+).

---

## 4. Разбор спецификации (`spec_parser.rb`)

Из `provider_api.yaml` собрать в IR:

- **Методы** — все `paths` × HTTP-глаголы. В эталоне 5: `POST /payouts`, `GET /payouts/{id}`, `POST /payouts/{id}/cancel`, `POST /webhooks/payout`, `GET /balance`.
- **Авторизация** — из `components.securitySchemes` (`ApiKeyAuth`, header `X-API-Key`).
- **Идемпотентность** — параметр `Idempotency-Key` (header, uuid).
- **Схемы** — `CreatePayoutRequest`, `PayoutResponse`, `Recipient`, `PayoutError`, `WebhookPayload`: типы, обязательные/необязательные поля, `minimum`, `pattern`, `enum`, `maxLength`.
- **Статусы операций** — enum `pending / processing / completed / failed / cancelled`.
- **Ошибки** — коды ответов (400/401/402/409/422/429/500) и `PayoutError.code`.
- **Webhook** — endpoint, события (`payout.completed/failed/processing/cancelled`), подпись `X-NovaPay-Signature` (HMAC-SHA256).

Любой нераспознанный или неоднозначный элемент → запись в `report` (предупреждение, **не** падение). Битый/невалидный YAML → внятное сообщение об ошибке, а не стектрейс.

---

## 5. Преобразование данных

**Статусы (провайдер → Space Payments):**
```ruby
STATUS_MAP = {
  'pending'    => 'in_progress',
  'processing' => 'in_progress',
  'completed'  => 'approved',
  'failed'     => 'rejected',
  'cancelled'  => 'rejected'
}.freeze
```

**Ошибки (HTTP → действие):**

| HTTP | code | Действие |
|------|------|----------|
| 400 / 422 | validation_error | reject |
| 401 | unauthorized | alert ops, block provider |
| 402 | insufficient_balance | retry later |
| 429 | rate_limit_exceeded | retry with backoff |
| 500 | internal_error | retry, alert ops |

**Форматы и поля:**
- Сумма: рубли → копейки (`amount * 100`), минимум 100000 коп. (1000 RUB).
- Реквизиты: `operation.payout_requisite.dig('sbp', 'phone' / 'bank_code' / 'bank_name')` → объект `recipient`.
- Обязательные поля запроса: `[amount, currency, external_id, recipient]`; необязательные обрабатываются мягко.

Правила маппинга вынести в `config/mapping.yml` — чтобы добавлять/переопределять без правки ядра.

---

## 6. Контракт генерируемого сервиса

Наследует `Provider::BaseService`, реализует 4 метода:

```ruby
class Provider
  class NovapayService < BaseService
    BASE_URL = ENV.fetch('NOVAPAY_BASE_URL', 'https://api.sandbox.novapay.example/v1')

    def check_conditions(operation, request_method)
      base_result = super
      return base_result if base_result.failed?
      return failure(:unprocessable_entity, 'amount_too_low') if operation.amount < 1000
      success
    end

    def create_request(operation, request_method = 'create')
      # POST /payouts + auth_headers + Idempotency-Key
      # rescue RateLimitError / UnauthorizedError → failure(...)
    end

    def fetch_status(operation)
      # GET /payouts/{id} → map_status(response.body['status'])
    end

    def process_callback(payload)
      verify_signature!(payload)             # HMAC-SHA256 из X-NovaPay-Signature
      # event → approve_operation / reject_operation / failure(:unprocessable_entity, 'unknown_event')
    end
  end
end
```

Обязательно: `auth_headers` (X-API-Key), `build_payout_payload`, `parse_create_response`, `verify_signature!`, обработка `RateLimitError` / `UnauthorizedError`, конфигурация адресов через ENV.

---

## 7. Универсальность (ключевой критерий)

- В логике генератора **нет** литералов `novapay` / `sbp` — только в IR и шаблонах.
- Проверка на втором синтетическом YAML (другой набор методов и полей) — код отрабатывает без правок.
- Правила маппинга статусов/ошибок конфигурируемы (`config/mapping.yml`).
- Неподдерживаемые/неоднозначные элементы спецификации — не молча, а через `report`.

---

## 8. Definition of Done

- [ ] `./integrate --spec provider_api.yaml --provider novapay` создаёт 3 файла за один прогон.
- [ ] `output/*_service.rb` проходит `ruby -c` и отрабатывает фикстуры из `fixtures.json`.
- [ ] Распознаны: методы, параметры, авторизация, идемпотентность, статусы, ошибки, webhook + подпись.
- [ ] Понятный вывод в консоль: что распарсили → что сгенерировали → предупреждения.
- [ ] Битый YAML и неподдержанные элементы → внятные сообщения, без стектрейса.
- [ ] Работает на втором YAML без изменений кода (доказательство универсальности).
- [ ] `README.md` с инструкцией запуска и настройки.
- [ ] Тесты (RSpec/Minitest) на парсер и мапперы.

---

## 9. Соответствие критериям оценки

| Раздел ТЗ | Критерий кейса | Баллы (эксперты) |
|-----------|----------------|:---:|
| §4 Разбор спецификации | Корректность разбора API | 20 |
| §6 Контракт сервиса | Генерация интеграционного сервиса | 25 |
| §5 Преобразование данных | Корректность преобразования | 15 |
| §7 Универсальность | Универсальность решения | 15 |
| §2, §8 CLI + README | Понятность использования | 15 |
| §3 Архитектура + обработка ошибок | Качество технической реализации | 10 |

---

## 10. Порядок работ

1. IR + `spec_parser` — фундамент.
2. Мапперы (статусы / ошибки / поля) + `config/mapping.yml`.
3. `service_generator` + ERB-шаблон сервиса.
4. `docs_generator` + `fixtures_generator`.
5. CLI + `report` (вывод и предупреждения).
6. Проверка универсальности на втором YAML, тесты, README.
