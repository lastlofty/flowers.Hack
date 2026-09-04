# Контракт fixtures.json и общих интерфейсов

Владелец формата `fixtures.json` — разработчик №1 (ядро). Verifier и сгенерированные
тесты (зона разработчика №2) читают этот формат. Любое изменение — согласовать здесь
до реализации.

## Текущий формат `fixtures.json`

```jsonc
{
  "provider": "novapay",
  "base_url": "https://api.sandbox.novapay.example/v1",
  "auth": { "type": "apiKey", "header": "X-API-Key", "credentials_field": "api_key" },

  "create_request": {
    "endpoint": "POST /payouts",
    "request": { ... },            // пример тела запроса (если есть в OpenAPI)
    "response_201": { ... },       // тело ответа
    "expected_201": {              // ожидаемый результат маппинга
      "status": "success",
      "provider_operation_id": "np_7f3a9b2c",
      "operation_status": "in_progress"
    },
    "response_422": { ... },
    "expected_422": { "status": "failed", "provider_code": "validation_error" }
  },

  "fetch_status": {
    "endpoint": "GET /payouts/{payout_id}",
    "response_200": { "id": "...", "status": "completed" },
    "expected_200": { "status": "success", "operation_status": "approved" }
  },

  "callback": {
    "endpoint": "POST /webhooks/payout",
    "signature_header": "X-NovaPay-Signature",
    "signature_alg": "SHA256",
    "signature_encoding": "hex",
    "completed": {
      "payload": { "event": "payout.completed", "payout_id": "...", "status": "completed" },
      "expected_operation_status": "approved"
    }
  }
}
```

### Правила

- Ключи `response_<code>` — тело ответа для HTTP-кода `<code>`.
- Ключи `expected_<code>` — ожидаемый результат: `status` (success/failed),
  `operation_status` (внутренний статус) и/или `provider_code`.
- Блок `callback.<name>` содержит `payload` и `expected_operation_status`.
- `signature_alg` и `signature_encoding` в блоке `callback` нужны верификатору,
  чтобы вычислить подпись.

## Различение примера из OpenAPI и синтетического сценария (планируется)

Если в спеке нет inline-примера, ядро синтезирует `response_201` / `response_200` из
enum статусов. **Предложение** (согласовать): добавить в каждый блок поле
`"source": "openapi" | "synthetic"`, чтобы верификатор и отчёты отличали реальные
примеры от синтезированных. Изменение аддитивное (старые ключи сохраняются).

## Предложение: raw-body для проверки подписи callback (нужно согласование)

**Проблема (P1 §8).** Сейчас `process_callback(payload)` получает уже разобранный JSON;
повторная сериализация меняет байты, поэтому подпись по исходному телу с отступами не
совпадает. Подпись должна проверяться по **исходным байтам**.

**Предлагаемый контракт** (меняет сигнатуру — требует правок Verifier и
`service_spec.rb.erb` у разработчика №2):

```ruby
# было
def process_callback(payload)                       # payload — разобранный Hash

# станет
def process_callback(raw_body, signature, headers = {})
  data = JSON.parse(raw_body)
  verify_signature!(raw_body, signature)            # HMAC по raw_body
  # ... маршрутизация по data['event']
end
```

- `raw_body` — строка с исходным телом запроса; `signature` — значение заголовка
  подписи (напр. `X-NovaPay-Signature`), передаётся **отдельно**, не внутри payload.
- Фикстуры callback уже несут `signature_alg`/`signature_encoding`; верификатор
  считает подпись по строке `JSON.generate(payload)` и передаёт её отдельно.

Порядок: сначала договорённость здесь → правки Verifier/`service_spec` → смена
сигнатуры в шаблоне сервиса. До согласования сохраняем текущий `process_callback(payload)`.

## Изменения общего контракта в этом проходе (для разработчика №2)

- `Paybridge.generate/parse_only` — сигнатуры сохранены; добавлены ключи модели
  (`create_success_codes` в IR), старые не удалялись.
- Новые внутренние коды результата сервиса: `incomplete_response` (нет id/неизвестный
  статус в успешном ответе), `missing_requisite` (нет обязательного реквизита способа).
- `amount` в IR: `min_native` (минимум в нативных единицах) вместо `min_major`.
- Валидация `overrides` (`amount_unit`, `signature_encoding`) — неверные значения →
  `GenerationError`.
- Авторизация резолвится по `security` операции/глобальному; неподдержанные схемы →
  пустые заголовки + warning (не фейковый api_key).
- Вся вставка данных спеки в Ruby идёт через `Paybridge::Safe` (экранирование).
