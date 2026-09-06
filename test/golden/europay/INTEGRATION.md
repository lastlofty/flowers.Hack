# EuroPay SEPA API Integration Guide

> Сгенерировано PayBridge 1.0.0 из `europay_api.yaml` (EuroPay SEPA API v3.0.0).
> Сервис: `Provider::EuropayService < Provider::BaseService`.
> spec sha256: `2fabca5a34b11593d2945f237d7e13a48ae0d8978dc3014ad90fb794ea5fdbd6`

## Авторизация

- Тип: apiKey
- Header: `X-Auth-Token: <credentials.api_key>`
- Хранение: `providers.credentials` (encrypted)

## Конфигурация подключения

| Переменная | Назначение | По умолчанию |
|------------|-----------|--------------|
| `EUROPAY_BASE_URL` | Базовый URL API | `https://sandbox.europay.example/v3` |
| `credentials.api_key` | Ключ авторизации | — (обязателен) |
| `credentials.callback_secret` | Секрет для проверки подписи webhook | — (обязателен) |

## Методы

| Метод сервиса | Endpoint | Назначение | Idempotency |
|---------------|----------|-----------|-------------|
| create_request | POST `/payments` | Создать платёж | — |
| fetch_status | GET `/payments/{payment_id}` | Статус платежа | — |
| process_callback | POST `/webhooks/payment` | Callback | `X-EuroPay-Signature` |

## Формат данных

- Сумма передаётся в мажорных единицах. Минимум — 1 EUR.
- Валюта — `EUR`.
- `order_id` — ID операции мерчанта (`operation.id`).

## Маппинг статусов

| Provider | Space Payments |
|----------|----------------|
| authorized | in_progress |
| captured | approved |
| declined | rejected |
| refunded | rejected |

## Обработка ошибок

| HTTP | Внутренний код | Действие |
|------|----------------|----------|
| 401 | `invalid_credentials` | alert ops, block provider |
| 404 | `not_found` | reject |
| 422 | `validation_error` | reject |
| 500 | `internal_error` | retry, alert ops |

## Webhook

- Путь: `POST /webhooks/payment`
- События: `payment.captured`, `payment.declined`, `payment.refunded`

### Проверка подписи

```
X-EuroPay-Signature = hex( HMAC-SHA256(request_body, credentials.callback_secret) )
```

`verify_signature!` сравнивает подпись за постоянное время; несовпадение → `Provider::UnauthorizedError`.

> Заголовок `X-EuroPay-Signature` приходит отдельно от тела. В боевом
> контроллере передайте исходные байты тела и значение заголовка отдельными
> аргументами в `process_callback(raw_body, signature, headers)`.

## Файлы интеграции

- `europay_service.rb` — сервис (контракт `BaseService`).
- `base_service.rb` — каркас платформы (предоставляется Space Payments).
- `fixtures.json` — примеры запросов, ответов и уведомлений для тестов.
