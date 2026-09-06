#!/usr/bin/env bash
# Качает реальные публичные OpenAPI-спеки для проверки универсальности.
# ЮKassa уже закоммичена (338 КБ); Stripe (6.4 МБ) не хранится в репозитории.
set -euo pipefail
dir="$(cd "$(dirname "$0")" && pwd)"

echo "Stripe -> $dir/stripe.yaml"
curl -sL -o "$dir/stripe.yaml" \
  "https://raw.githubusercontent.com/stripe/openapi/master/openapi/spec3.yaml"

echo "ЮKassa -> $dir/yookassa.yaml"
curl -sL -o "$dir/yookassa.yaml" \
  "https://yookassa.ru/developers/api/yookassa-openapi-specification.yaml"

echo "Готово. Проверить: ruby exe/integrate validate --spec $dir/yookassa.yaml --provider yookassa"
