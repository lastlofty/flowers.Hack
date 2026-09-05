# Контракт Web API

Все JSON-ответы содержат `request_id`; тот же идентификатор возвращается в
`X-Request-ID`. Клиент может прислать безопасный `X-Request-ID`, иначе API создаст
`req_<24 hex>`.

## Маршруты

| Метод | Путь | Результат |
|---|---|---|
| POST | `/api/validate` | Распознанная модель без записи интеграции |
| POST | `/api/integrations` | Генерация и сохранение |
| GET | `/api/integrations/:id` | Метаданные и последний verify |
| GET | `/api/integrations/:id/model` | Модель из того же parse-pass, что генерация |
| GET | `/api/integrations/:id/files/:name` | Разрешённый артефакт |
| GET | `/api/integrations/:id/archive` | ZIP разрешённых артефактов |
| POST | `/api/integrations/:id/verify` | Проверка в ограниченном контейнере |
| GET | `/api/integrations?page=1&per_page=20` | История, новые сначала; `per_page <= 100` |
| GET | `/api/health` | Живость и `verification_available` |

Прежние поля `id`, `provider`, `status`, `endpoints`, `files`, `warnings`,
`valid`, `syntax_error`, `created_at`, а также `passed`, `failed`,
`cases[].name/ok/detail` сохранены.

## Пример метаданных

```json
{
  "id": "int_0123456789abcdef01234567",
  "provider": "novapay",
  "status": "generated",
  "endpoints": [],
  "files": ["INTEGRATION.md", "base_service.rb", "fixtures.json", "novapay_service.rb"],
  "warnings": [],
  "valid": true,
  "syntax_error": null,
  "created_at": "2026-09-05T07:00:00Z",
  "verification": {
    "status": "not_run",
    "passed": 0,
    "failed": 0,
    "skipped": 0,
    "checked_at": null,
    "cases": []
  },
  "request_id": "req_example"
}
```

## Примеры verify

Завершённый набор с провалом возвращается с HTTP 200:

```json
{
  "status": "failed",
  "passed": 1,
  "failed": 1,
  "skipped": 0,
  "checked_at": "2026-09-05T07:00:00Z",
  "cases": [
    { "name": "create_request.response_200", "status": "passed", "ok": true,
      "detail": "Результат и исходящий запрос соответствуют сценарию" },
    { "name": "callback.invalid_signature", "status": "failed", "ok": false,
      "detail": "Неверная подпись была принята" }
  ],
  "request_id": "req_example"
}
```

Если выполненные проверки прошли, но часть данных отсутствует, статус `partial`,
а кейс имеет `status: skipped`, `ok: null` и причину. Ноль выполненных кейсов также
`partial`, а не `passed`.

Недоступная изоляция:

```json
{
  "error": {
    "code": "verification_unavailable",
    "message": "Безопасная среда проверки недоступна"
  },
  "request_id": "req_example"
}
```

## Ошибки

| HTTP | Коды |
|---|---|
| 400 | `missing_spec`, `invalid_provider`, `invalid_type`, `invalid_pagination` |
| 404 | `not_found` |
| 413 | `too_large` |
| 422 | `validation_failed`, `generation_failed`, `verification_failed` |
| 503 | `verification_unavailable` |
| 504 | `generation_timeout`, `verification_timeout` |
| 500 | `internal_error` без внутренних деталей |

Метаданные, модель и последний verify атомарно сохраняются в каталоге интеграции и
восстанавливаются после рестарта. `metadata.json` не входит в список скачиваемых
файлов и ZIP.

