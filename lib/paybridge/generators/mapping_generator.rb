# frozen_string_literal: true

require 'yaml'

module Paybridge
  module Generators
    # `<provider>_mapping.yml` — «что инструмент понял»: роли эндпоинтов, авторизация,
    # единица суммы, маппинги статусов/ошибок, поля для ручного заполнения и провенанс
    # (sha256 спеки, версия генератора). Главный файл для проверки глазами и для CI:
    # человек за минуту видит все решения генератора, не читая сгенерированный код.
    #
    # Данные детерминированы (упорядоченные хэши -> стабильный YAML) — годится в golden.
    class MappingGenerator
      attr_reader :spec, :spec_source

      def initialize(spec, spec_source: 'provider_api.yaml', **_opts)
        @spec = spec
        @spec_source = spec_source
      end

      def filename
        "#{spec.provider_name}_mapping.yml"
      end

      def render
        "#{YAML.dump(stringify(build))}"
      end

      private

      def build
        {
          'provenance' => provenance,
          'recognized' => recognized,
          'auth' => auth_block,
          'idempotency_header' => spec.idempotency_header,
          'amount' => amount_block,
          'currency' => spec.currency,
          'status_map' => spec.status_map,
          'error_map' => spec.error_map,
          'recipient_methods' => recipient_methods,
          'manual_fields' => manual_fields,
          'diagnostics' => diagnostics,
          'summary' => summary
        }
      end

      # Диагностика с уровнями (info/warn/error) — сгруппирована для чтения глазами.
      def diagnostics
        spec.report.diagnostics_by_level.transform_keys(&:to_s)
      end

      def provenance
        {
          'generator' => "PayBridge #{Paybridge::VERSION}",
          'provider' => spec.provider_name,
          'spec_source' => spec_source,
          'spec_sha256' => spec.spec_sha256
        }
      end

      # Выбранные роли: как endpoint, так и явная пометка, что метод не найден.
      def recognized
        {
          'create' => endpoint_str(spec.create_endpoint),
          'status' => endpoint_str(spec.status_endpoint),
          'cancel' => endpoint_str(spec.cancel_endpoint),
          'webhook' => spec.webhook && "POST #{spec.webhook.path}"
        }
      end

      def endpoint_str(endpoint)
        endpoint && "#{endpoint.http_method.upcase} #{endpoint.path}"
      end

      def auth_block
        return nil unless spec.auth

        {
          'type' => spec.auth.scheme_type,
          'scheme' => spec.auth.http_scheme,
          'location' => spec.auth.location,
          'header' => spec.auth.header_name,
          'credentials_field' => spec.auth.credentials_field
        }
      end

      def amount_block
        return nil unless spec.amount

        {
          'field' => spec.amount[:field],
          'unit' => spec.amount[:minor_units] ? 'minor' : 'major',
          'min_native' => spec.amount[:min_native]
        }
      end

      def recipient_methods
        return nil unless spec.recipient_spec

        spec.recipient_spec['methods'].keys
      end

      def manual_fields
        spec.report.todos.map(&:to_h).map { |t| t.transform_keys(&:to_s) }
      end

      def summary
        by_level = spec.report.diagnostics_by_level
        {
          'endpoints' => spec.endpoints.size,
          'manual_fields' => spec.report.todos.size,
          'diagnostics' => {
            'info' => (by_level[:info] || []).size,
            'warn' => (by_level[:warn] || []).size,
            'error' => (by_level[:error] || []).size
          }
        }
      end

      # Ключи-символы -> строки рекурсивно (стабильный, читаемый YAML без `:sym`).
      def stringify(value)
        case value
        when Hash  then value.each_with_object({}) { |(k, v), h| h[k.to_s] = stringify(v) }
        when Array then value.map { |item| stringify(item) }
        else value
        end
      end
    end
  end
end
