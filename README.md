# PayBridge — генератор интеграций с платёжными провайдерами

Кейс **Space Payments**. Инструмент принимает OpenAPI-спецификацию платёжного
провайдера (`provider_api.yaml`) и генерирует готовую интеграцию под контракт
`Provider::BaseService`: сервис, документацию и тестовые фикстуры.

Ручная интеграция провайдера занимает 2–5 дней. PayBridge сводит её к одному запуску.

> **Стек:** только Ruby, без внешних рантайм-зависимостей (psych, erb, optparse,
> json, openssl — всё из stdlib). Без нейросетей: разбор спецификации полностью
> детерминированный.

## Установка

```bash
git clone https://github.com/lastlofty/flowers.Hack.git
cd flowers.Hack
ruby -v   # нужен Ruby >= 3.0
```

Гемы не требуются — генератор работает на stdlib.

## Запуск

```bash
ruby exe/integrate --spec examples/provider_api.yaml --provider novapay
```

Вывод:

```
Parsing spec...
Found 5 endpoints: POST /payouts, GET /payouts/{payout_id}, POST /payouts/{payout_id}/cancel, POST /webhooks/payout, GET /balance
Auth: apiKey (header: X-API-Key)
Webhook signature: X-NovaPay-Signature (HMAC-SHA256)
Generating service...
Generating integration guide...
Generating test fixtures...

Output:
  ./output/novapay_service.rb
  ./output/INTEGRATION.md
  ./output/fixtures.json
  ./output/base_service.rb
```

### Опции

| Флаг | Назначение | По умолчанию |
|------|-----------|--------------|
| `--spec` | Путь к OpenAPI-спецификации | — (обязателен) |
| `--provider` | Имя провайдера | — (обязателен) |
| `--output` | Каталог результатов | `./output` |
| `--config` | Файл правил маппинга | `config/mapping.yml` |
| `--lang` | Язык генерации (только `ruby`) | `ruby` |

## Что генерируется

1. **`<provider>_service.rb`** — сервис по контракту `Provider::BaseService`
   (`check_conditions`, `create_request`, `fetch_status`, `process_callback`).
2. **`INTEGRATION.md`** — авторизация, методы, маппинг статусов и ошибок, webhook.
3. **`fixtures.json`** — примеры запросов, ответов и уведомлений с ожидаемыми результатами.
4. **`base_service.rb`** — каркас платформы (копируется, чтобы результат был запускаемым).

## Архитектура

```
provider_api.yaml
      │
      ▼
  SpecParser ──►  IR::Spec  ──►  ServiceGenerator ──► *_service.rb
 (YAML → IR)     (модель)        DocsGenerator    ──► INTEGRATION.md
      │                          FixturesGenerator──► fixtures.json
      ▼
   Report (предупреждения о неподдержанных элементах)
```

- **`lib/paybridge/spec_parser.rb`** — разбор YAML, разрешение `$ref`, классификация
  endpoint'ов (create/status/cancel/webhook), извлечение auth, статусов, ошибок, webhook.
- **`lib/paybridge/mappers/`** — статусы, ошибки, построение тела запроса из схемы.
- **`lib/paybridge/generators/`** + **`templates/`** — рендер файлов через ERB.
- **`config/mapping.yml`** — правила маппинга статусов/ошибок. Расширяются без правки кода.

Ядро не содержит хардкода конкретного провайдера: другой YAML на входе → другая
интеграция на выходе, тот же код генератора. Неподдержанные/неоднозначные элементы
спецификации не роняют процесс — попадают в `Report` и печатаются в конце.

## Тесты

Используется `minitest` из stdlib — внешние гемы не нужны.

```bash
ruby -Ilib -Itest test/test_spec_parser.rb
ruby -Ilib -Itest test/test_generators.rb
```

## Соответствие критериям кейса

| Критерий | Где реализовано |
|----------|-----------------|
| Разбор API-спецификации | `spec_parser.rb` |
| Генерация сервиса | `generators/service_generator.rb`, `templates/service.rb.erb` |
| Преобразование данных | `mappers/` + `config/mapping.yml` |
| Универсальность | IR + шаблоны + `Report` о неподдержанном |
| Документация и фикстуры | `docs_generator.rb`, `fixtures_generator.rb` |
| Удобство/демо | `cli.rb` (один процесс, понятный вывод, обработка ошибок) |

## Ограничения текущей версии

- Проверка подписи webhook читает подпись из `payload['_signature']`; в боевом
  контроллере заголовок `X-NovaPay-Signature` нужно прокинуть из `request.headers`.
- Маппинг вложенных реквизитов использует конвенцию `operation.payout_requisite`.
- Поддерживается генерация только на Ruby.
