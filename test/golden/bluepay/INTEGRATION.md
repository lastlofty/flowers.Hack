# BluePay Transfer API Integration Guide

> Сгенерировано PayBridge 1.0.0 из `bluepay_api.yaml` (BluePay Transfer API v2.1.0).
> Сервис: `Provider::BluepayService < Provider::BaseService`.
> spec sha256: `3d9c558299d8d642b100a36f9503324b67b3be2c029dd1e95201bd2af9b0fc80`

## Авторизация

- Тип: apiKey
- Header: `X-Api-Token: <credentials.api_key>`
- Хранение: `providers.credentials` (encrypted)

## Конфигурация подключения

| Переменная | Назначение | По умолчанию |
|------------|-----------|--------------|
| `BLUEPAY_BASE_URL` | Базовый URL API | `https://sandbox.bluepay.example/api` |
| `credentials.api_key` | Ключ авторизации | — (обязателен) |
| `credentials.callback_secret` | Секрет для проверки подписи webhook | — (обязателен) |

## Методы

| Метод сервиса | Endpoint | Назначение | Idempotency |
|---------------|----------|-----------|-------------|
| create_request | POST `/transfers` | Создать перевод | — |
| fetch_status | GET `/transfers/{transfer_id}` | Статус перевода | — |
| process_callback | POST `/hooks/transfer` | Callback | `X-BluePay-Signature` |

## Формат данных

- Сумма передаётся **в минорных единицах** (`operation.amount * 100`). Минимум — 100 минорных единиц.
- Преобразование выполняется десятичной арифметикой BigDecimal; половина минимальной единицы округляется от нуля (ROUND_HALF_UP). Проверка минимума и отправка используют одно правило. Поддержан масштаб 100 (две десятичные позиции); для других валютных масштабов нужен отдельный контракт.
- Валюта — `USD`.
- `reference` — ID операции мерчанта (`operation.id`).

## Маппинг статусов

| Provider | Space Payments |
|----------|----------------|
| created | in_progress |
| sent | in_progress |
| done | approved |
| failed | rejected |

## Обработка ошибок

| HTTP | Внутренний код | Действие |
|------|----------------|----------|
| 401 | `invalid_credentials` | alert ops, block provider |
| 404 | `not_found` | reject |
| 422 | `validation_error` | reject |
| 429 | `rate_limit` | retry with backoff |
| 500 | `internal_error` | retry, alert ops |

## Webhook

- Путь: `POST /hooks/transfer`
- События: `transfer.done`, `transfer.failed`, `transfer.sent`

### Проверка подписи

```
X-BluePay-Signature = hex( HMAC-SHA512(request_body, credentials.callback_secret) )
```

`verify_signature!` сравнивает подпись за постоянное время; несовпадение → `Provider::UnauthorizedError`.

> Заголовок `X-BluePay-Signature` приходит отдельно от тела. В боевом
> контроллере передайте исходные байты тела и значение заголовка отдельными
> аргументами в `process_callback(raw_body, signature, headers)`.

## Файлы интеграции

- `bluepay_service.rb` — сервис (контракт `BaseService`).
- `base_service.rb` — каркас платформы (предоставляется Space Payments).
- `fixtures.json` — примеры запросов, ответов и уведомлений для тестов.
