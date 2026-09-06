# Проверка универсальности на РЕАЛЬНЫХ спеках

Генератор прогнан на публичных боевых OpenAPI-спецификациях из **официальных
источников провайдеров** — не на синтетике. И это не просто «сгенерировали и
показали список»: по каждому провайдеру прогоняется **verify** — фикстуры
воспроизводятся против сгенерированного сервиса (форма запроса, авторизация,
статусы, callback). Контракт: компилирующийся сервис + **честные предупреждения**
там, где данных нет, и никаких молчаливых догадок / крашей.

| Спека | Размер | Методов | Авторизация | `ruby -c` | **verify** | Вручную | Предупр. |
|-------|-------:|--------:|-------------|:---------:|:----------:|:-------:|:--------:|
| **ЮKassa** (YooMoney API) | 338 КБ | 34 | HTTP Basic | ✅ | **3 passed** / 1 skip | 0 | 25 |
| **Adyen** Checkout v71 | 822 КБ | 28 | apiKey (X-API-Key) | ✅ | **3 passed** / 1 skip | 3 | 5 |
| **Stripe** (v2026-08-26) | 6.4 МБ | 594 | HTTP Bearer | ✅ | 1 passed / 1 skip | 0 | 17 |

> `verify` skip у всех троих — только callback: подпись webhook не описана
> непосредственно в схеме (её задают в кабинете провайдера). create/status/auth —
> проверены и проходят (кроме Stripe, где 594 метода не дают однозначного create —
> это ограничение задокументировано ниже).

## ЮKassa

- Верно определены: create `POST /payments`, status `GET /payments/{id}`,
  cancel `POST /payments/{id}/cancel`, webhook `POST /webhooks`.
- Авторизация HTTP Basic (`shopId:secretKey`) — сгенерирована корректно.
- Статусы: `pending → in_progress`, `succeeded → approved`, `canceled → rejected`;
  `waiting_for_capture` не в `mapping.yml` → **предупреждение** + дефолт (не молча).
- 16 полей запроса (amount как вложенный объект `{value,currency}`, `confirmation`,
  `receipt` …) без конвенции → **отправляются `nil` + предупреждение** с подсказкой
  задать `overrides`. Это и есть «честные границы»: генератор не выдумывает маппинг.

## Adyen (Checkout API v71)

- Официальная спека из репозитория Adyen (`Adyen/adyen-openapi`), OpenAPI 3.1.
- Верно определены create `POST /payments` и status-запрос; авторизация
  `apiKey` (`X-API-Key`) сгенерирована корректно — **verify 3 passed**.
- 3 обязательных поля (`merchantAccount`, `reference`, `returnUrl` …) невозможно
  вывести из модели операции → помечены **«заполнить вручную»** с TODO-маркером
  в коде и подсказкой. Это ровно наша фича «честные границы + что делать дальше»,
  показанная на боевом провайдере.

## Stripe

- 594 метода, 6.4 МБ — парсинг и генерация за ~1 c благодаря бюджету разворота
  `$ref` (плотный граф ссылок Stripe иначе даёт комбинаторный взрыв).
- Авторизация HTTP Bearer. Сервис компилируется.
- create выбран как первый POST (`/v1/account_links`) — Stripe имеет много
  POST-методов; выбор конкретного — через явное указание (ограничение честно
  задокументировано).

## Как воспроизвести

```bash
bash examples/real/fetch.sh                 # скачать спеки (Stripe большой)
ruby exe/integrate validate --spec examples/real/yookassa.yaml --provider yookassa
ruby exe/integrate --spec examples/real/yookassa.yaml --provider yookassa
ruby -c output/yookassa_service.rb
```

> `examples/real/stripe.yaml` (6.4 МБ) не хранится в репозитории — качается скриптом.
> `examples/real/yookassa.yaml` закоммичен (338 КБ). Регрессия — `test/test_real_specs.rb`
> (генерирует и проверяет `ruby -c` для всех спек, что лежат в `examples/real/`).
