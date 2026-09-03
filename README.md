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
ТЗ_PayBridge.md        # ТЗ генератора
ТЗ_бэкенд.md           # ТЗ бэкенда (для напарника)
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

## Тесты

```bash
bundle exec ruby -Itest test/test_api.rb
```

## API

| Метод | Путь | Назначение |
|-------|------|-----------|
| POST | `/api/integrations` | Загрузить спецификацию, сгенерировать интеграцию |
| GET | `/api/integrations/:id` | Метаданные + файлы + предупреждения |
| GET | `/api/integrations/:id/files/:name` | Скачать один файл |
| GET | `/api/integrations/:id/archive` | Скачать zip |
| GET | `/api/health` | Проверка живости |
