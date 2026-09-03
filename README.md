# PayBridge — генератор интеграций с платёжными провайдерами

Кейс Space Payments: инструмент принимает OpenAPI-спецификацию провайдера
(`provider_api.yaml`) и генерирует готовую интеграцию под контракт
`Provider::BaseService` — Ruby-сервис, `INTEGRATION.md` и `fixtures.json`.

Только Ruby, открытый исходный код, без нейросетей.

## Состав репозитория

```
lib/paybridge/         # ядро-генератор (парсер, мапперы, IR)  — WIP
lib/paybridge.rb       # фасад Paybridge.generate (сейчас заглушка)
app/                   # веб-бэкенд (Sinatra) поверх генератора
public/                # простой UI загрузки спецификации
config/mapping.yml     # правила маппинга статусов/ошибок (без хардкода провайдера)
examples/              # пример provider_api.yaml
test/                  # тесты (minitest + rack-test)
ТЗ_PayBridge.md        # ТЗ ядра-генератора + CLI (тимлид)
ТЗ_напарник.md         # ТЗ: проверка/качество/документация/демо (2-й участник)
ТЗ_веб.md              # ТЗ веб-интерфейса (3-й участник)
```

## Бэкенд: запуск

```bash
bundle install
bundle exec rackup      # http://localhost:9292
```

Проверка:

```bash
curl -X POST http://localhost:9292/api/integrations \
  -F "spec=@examples/provider_api.yaml" \
  -F "provider=novapay"
```

UI — на `http://localhost:9292/`.

> Сейчас `Paybridge.generate` — заглушка: возвращает распознанные endpoints и
> файлы-плейсхолдеры. Когда ядро (`lib/paybridge/`) будет готово, внутренности
> фасада заменяются на реальную генерацию — контракт (`Generation`,
> `GenerationError`, сигнатура) при этом не меняется.

## Генератор: запуск (CLI)

```bash
ruby exe/integrate --spec examples/provider_api.yaml --provider novapay
```

Универсальность — тот же генератор на другом провайдере:

```bash
ruby exe/integrate --spec examples/bluepay_api.yaml --provider bluepay
```

Результат — в `./output/` (`<provider>_service.rb`, `INTEGRATION.md`, `fixtures.json`, `base_service.rb`).

Уточнения того, что нельзя достать из структуры OpenAPI (единица суммы, кодировка подписи,
условная обязательность полей) — через опциональный overrides-файл; чего в нём нет, ядро
выведет эвристикой и честно предупредит:

```bash
ruby exe/integrate --spec examples/provider_api.yaml --provider novapay --overrides examples/overrides.novapay.yml
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
| POST | `/api/integrations` | Загрузить спецификацию, сгенерировать интеграцию |
| GET | `/api/integrations/:id` | Метаданные + файлы + предупреждения |
| GET | `/api/integrations/:id/files/:name` | Скачать один файл |
| GET | `/api/integrations/:id/archive` | Скачать zip |
| GET | `/api/health` | Проверка живости |
