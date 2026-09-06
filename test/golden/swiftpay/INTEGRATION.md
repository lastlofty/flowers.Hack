# SwiftPay API Integration Guide

> Сгенерировано PayBridge 1.0.0 из `swiftpay_api.yaml` (SwiftPay API v1.0.0).
> Сервис: `Provider::SwiftpayService < Provider::BaseService`.
> spec sha256: `d4d9a3ec1715ef3bb3653fc9dec496cafb4d48e60daf67e3723a4bec2655d745`

## Авторизация

- Тип: http
- Header: `Authorization: <credentials.token>`
- Хранение: `providers.credentials` (encrypted)

## Конфигурация подключения

| Переменная | Назначение | По умолчанию |
|------------|-----------|--------------|
| `SWIFTPAY_BASE_URL` | Базовый URL API | `https://sandbox.swiftpay.example/v1` |
| `credentials.token` | Ключ авторизации | — (обязателен) |

## Методы

| Метод сервиса | Endpoint | Назначение | Idempotency |
|---------------|----------|-----------|-------------|
| create_request | POST `/payments` | Создать платёж | — |
| fetch_status | GET `/payments/{payment_id}` | Статус платежа | — |

## Формат данных

- Сумма передаётся **в минорных единицах** (`operation.amount * 100`). Минимум — 100 минорных единиц.
- Преобразование выполняется десятичной арифметикой BigDecimal; половина минимальной единицы округляется от нуля (ROUND_HALF_UP). Проверка минимума и отправка используют одно правило. Поддержан масштаб 100 (две десятичные позиции); для других валютных масштабов нужен отдельный контракт.
- Валюта — `USD`.
- `reference` — ID операции мерчанта (`operation.id`).

## Маппинг статусов

| Provider | Space Payments |
|----------|----------------|
| pending | in_progress |
| completed | approved |
| failed | rejected |

## Обработка ошибок

| HTTP | Внутренний код | Действие |
|------|----------------|----------|
| 401 | `invalid_credentials` | alert ops, block provider |
| 404 | `not_found` | reject |
| 422 | `validation_error` | reject |
| 500 | `internal_error` | retry, alert ops |

## Файлы интеграции

- `swiftpay_service.rb` — сервис (контракт `BaseService`).
- `base_service.rb` — каркас платформы (предоставляется Space Payments).
- `fixtures.json` — примеры запросов, ответов и уведомлений для тестов.
