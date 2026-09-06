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
| **Adyen** Checkout v71 | 822 КБ | 28 | HTTP Basic¹ | ✅ | **3 passed** / 1 skip | 3 | 76 |
| **Klarna** Payments v1 | 59 КБ | 6 | не определена² | ✅ | **3 passed** / 1 skip | 4 | 22 |
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

- Официальная спека из репозитория Adyen (`Adyen/adyen-openapi`), OpenAPI 3.1,
  28 методов.
- Из 16 POST-методов create верно выбран `POST /payments` — благодаря
  ранжированию кандидатов по «платёжности» (иначе «первый попавшийся» дал бы
  `/applePay/sessions`). **verify 3 passed** (create/status/auth).
- ¹ Авторизация: Adyen поддерживает и `X-API-Key`, и HTTP Basic; в security
  `/payments` первым идёт Basic — его и генерируем (`Authorization: Basic …`).
  Нужен X-API-Key — `overrides.security_scheme: ApiKeyAuth` (проверено).
- `amount` — вложенный объект `{value, currency}`; currency без enum →
  `operation.currency` (нашёлся баг: verify-заглушка операции не несла currency —
  **починили**, теперь контракт операции включает валюту).
- 3 обязательных поля (`merchantAccount`, `paymentMethod`, `returnUrl`) невозможно
  вывести из модели операции → помечены **«заполнить вручную»** с TODO-маркером
  в коде и подсказкой. Это ровно наша фича «честные границы + что делать дальше»,
  показанная на боевом провайдере.

## Klarna (Payments API v1)

- Официальная спека (зеркало apis.guru), OpenAPI 3.0.
- Верно определены create `POST /payments/v1/sessions` и status
  `GET /payments/v1/sessions/{session_id}` — **verify 3 passed**.
- ² Авторизация: на операции создания в этой спеке нет явного `security`, схему
  вывести не удалось → генерируем **пустые** заголовки + предупреждение
  (не угадываем). verify проходит, т.к. и ожидание, и запрос без заголовка auth
  согласованы. В бою Klarna использует HTTP Basic — задаётся
  `overrides.security_scheme` (когда схема есть в `securitySchemes`).
- Adyen `/payments` — крупный объект: ~70 необязательных полей, которые мы не
  выводим из модели операции, честно помечены предупреждениями (отсюда 76).
- Вскрыл реальный баг устойчивости: спека содержит `example` с датой/временем
  без кавычек (`2038-01-19T03:14:07Z`) → `YAML.safe_load` ронял `Time`.
  **Починили**: Date/Time разрешены как безопасные value-классы (опасные
  `!ruby/object` по-прежнему запрещены). Теперь такие спеки грузятся.
- 4 обязательных поля (`order_amount`, `order_lines`, `purchase_country`,
  `purchase_currency`) → «заполнить вручную» с подсказками.

## Stripe

- 594 метода, 6.4 МБ — парсинг и генерация за ~1 c благодаря бюджету разворота
  `$ref` (плотный граф ссылок Stripe иначе даёт комбинаторный взрыв).
- Авторизация HTTP Bearer. Сервис компилируется.
- Ранжирование выбирает платёжный POST, но у Stripe их десятки — при
  необходимости целевой метод задаётся точно:
  `overrides.create_endpoint: "POST /v1/payment_intents"` (проверено).

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
