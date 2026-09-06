# NovaPay Payout API Integration Guide

> Сгенерировано PayBridge 1.0.0 из `provider_api.yaml` (NovaPay Payout API v1.0.0).
> Сервис: `Provider::NovapayService < Provider::BaseService`.
> spec sha256: `415f50ee36fb331dfab49ceed0e8ed3b0ebe16053d7e00dbabd32282f4396551`

## Авторизация

- Тип: apiKey
- Header: `X-API-Key: <credentials.api_key>`
- Хранение: `providers.credentials` (encrypted)

## Конфигурация подключения

| Переменная | Назначение | По умолчанию |
|------------|-----------|--------------|
| `NOVAPAY_BASE_URL` | Базовый URL API | `https://api.sandbox.novapay.example/v1` |
| `credentials.api_key` | Ключ авторизации | — (обязателен) |
| `credentials.callback_secret` | Секрет для проверки подписи webhook | — (обязателен) |

## Методы

| Метод сервиса | Endpoint | Назначение | Idempotency |
|---------------|----------|-----------|-------------|
| create_request | POST `/payouts` | Создать выплату | `Idempotency-Key` header |
| fetch_status | GET `/payouts/{payout_id}` | Получить статус выплаты | — |
| (отмена) | POST `/payouts/{payout_id}/cancel` | Отменить выплату | — |
| process_callback | POST `/webhooks/payout` | Callback | `X-NovaPay-Signature` |

## Формат данных

- Сумма передаётся **в минорных единицах** (`operation.amount * 100`). Минимум — 100000 минорных единиц.
- Преобразование выполняется десятичной арифметикой BigDecimal; половина минимальной единицы округляется от нуля (ROUND_HALF_UP). Проверка минимума и отправка используют одно правило. Поддержан масштаб 100 (две десятичные позиции); для других валютных масштабов нужен отдельный контракт.
- Валюта — `RUB`.
- `external_id` — ID операции мерчанта (`operation.id`).

## Маппинг статусов

| Provider | Space Payments |
|----------|----------------|
| pending | in_progress |
| processing | in_progress |
| completed | approved |
| failed | rejected |
| cancelled | rejected |

## Обработка ошибок

| HTTP | Внутренний код | Действие |
|------|----------------|----------|
| 400 | `validation_error` | reject |
| 401 | `invalid_credentials` | alert ops, block provider |
| 402 | `insufficient_balance` | retry later |
| 404 | `not_found` | reject |
| 409 | `duplicate` | treat as success (idempotent) |
| 422 | `validation_error` | reject |
| 429 | `rate_limit` | retry with backoff |
| 500 | `internal_error` | retry, alert ops |

## Webhook

- Путь: `POST /webhooks/payout`
- События: `payout.completed`, `payout.failed`, `payout.processing`, `payout.cancelled`

### Проверка подписи

```
X-NovaPay-Signature = hex( HMAC-SHA256(request_body, credentials.callback_secret) )
```

`verify_signature!` сравнивает подпись за постоянное время; несовпадение → `Provider::UnauthorizedError`.

> Заголовок `X-NovaPay-Signature` приходит отдельно от тела. В боевом
> контроллере прокиньте его в `process_callback` вместо чтения `payload['_signature']`.

## Файлы интеграции

- `novapay_service.rb` — сервис (контракт `BaseService`).
- `base_service.rb` — каркас платформы (предоставляется Space Payments).
- `fixtures.json` — примеры запросов, ответов и уведомлений для тестов.
