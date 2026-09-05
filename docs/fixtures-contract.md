# Контракт fixtures.json и callback

Актуальная версия контракта — `2`. Формат генерирует ядро PayBridge,
а Verifier и сгенерированные Minitest-тесты читают его как независимый набор
сценариев.

```jsonc
{
  "contract_version": 2,
  "provider": "novapay",
  "base_url": "https://api.sandbox.novapay.example/v1",
  "auth": {
    "type": "apiKey",
    "location": "header",
    "header": "X-API-Key",
    "credentials_field": "api_key"
  },
  "create_request": {
    "endpoint": "POST /payouts",
    "idempotency_header": "Idempotency-Key",
    "request": { "amount": 1500000 },
    "request_source": "openapi",
    "operation": {
      "amount": 15000.0,
      "id": "op_abc123",
      "payout_requisite": {},
      "provider_operation_id": "op_prov",
      "idempotency_key": "idem_1"
    },
    "response_201": { "id": "np_1", "status": "pending" },
    "expected_201": {
      "status": "success",
      "provider_operation_id": "np_1",
      "operation_status": "in_progress"
    },
    "source_201": "openapi",
    "response_409_idempotent": { "id": "np_1", "status": "pending" },
    "expected_409_idempotent": {
      "status": "success",
      "provider_operation_id": "np_1",
      "operation_status": "in_progress"
    },
    "source_409_idempotent": "synthetic",
    "response_409_conflict": { "error": { "code": "conflict" } },
    "expected_409_conflict": {
      "status": "failed",
      "provider_code": "conflict",
      "internal_code": "conflict"
    },
    "source_409_conflict": "synthetic"
  },
  "fetch_status": {
    "endpoint": "GET /payouts/{payout_id}",
    "response_200": { "id": "np_1", "status": "completed" },
    "expected_200": { "status": "success", "operation_status": "approved" },
    "source_200": "openapi"
  },
  "callback": {
    "endpoint": "POST /webhooks/payout",
    "signature_header": "X-NovaPay-Signature",
    "signature_alg": "SHA256",
    "signature_encoding": "hex",
    "completed": {
      "payload": { "event": "payout.completed", "payout_id": "np_1", "status": "completed" },
      "raw_body": "{\n  \"event\": \"payout.completed\",\n  \"payout_id\": \"np_1\",\n  \"status\": \"completed\"\n}",
      "source": "openapi",
      "expected_operation_status": "approved"
    }
  }
}
```

## Правила сценариев

- `response_<code>` / `expected_<code>` задают тело HTTP-ответа и ожидаемый
  результат сервиса. Допустим суффикс сценария, например
  `response_409_idempotent`.
- `source_<code>[_<scenario>]` и `callback.<name>.source` равны `openapi` или
  `synthetic`. Синтетический сценарий не выдаётся за факт из спеки.
- `operation` — независимый вход в `create_request`; ожидаемый JSON берётся
  из `request`, а не из того же метода сервиса.
- При идемпотентном create код `409` имеет два разных сценария:
  ответ с известными `id` и `status` — успешный повтор; обычная ошибка
  конфликта остаётся failed.
- В `expected` используются `status` (`success`/`failed`),
  `provider_operation_id`, `operation_status`, `provider_code` и `internal_code`.

## Callback и подпись

Контракт сервиса:

```ruby
def process_callback(raw_body, signature = nil, headers = {})
  payload = JSON.parse(raw_body)
  verify_signature!(raw_body, signature)
  # маршрутизация события
end
```

`raw_body` — исходная строка HTTP-body, а `signature` — значение заголовка
подписи. HMAC считается по байтам `raw_body` без повторной сериализации.
Поле `_signature` в JSON больше не является частью контракта. Невалидный JSON
возвращает failed-результат с `invalid_json`; неверная подпись вызывает
`Provider::UnauthorizedError`.
