# frozen_string_literal: true

require 'json'

module Paybridge
  module Generators
    # `<provider>.ir.json` — дамп внутреннего представления (IR), в которое
    # компилируется спека: методы с ролями и строками спеки, авторизация, маппинги
    # статусов/ошибок, сумма, реквизиты, тело запроса и диагностика. Аналог
    # «program.mir» у конкурентов — прозрачность того, ЧТО генератор понял, до кода.
    #
    # Детерминирован (упорядоченный JSON, пустые массивы нормализованы).
    class IrDumpGenerator
      attr_reader :spec

      def initialize(spec, **_opts)
        @spec = spec
      end

      def filename
        "#{spec.provider_name}.ir.json"
      end

      def render
        json = JSON.pretty_generate(build).gsub(/\[\n\s*\]/, '[]')
        "#{json}\n"
      end

      private

      def build
        {
          'provider' => spec.provider_name,
          'class' => spec.provider_class,
          'title' => spec.title,
          'version' => spec.version,
          'base_url' => spec.base_url,
          'spec_sha256' => spec.spec_sha256,
          'endpoints' => spec.endpoints.map { |e| endpoint(e) },
          'recognized' => recognized,
          'extra_operations' => spec.extra_operations || [],
          'auth' => auth,
          'idempotency_header' => spec.idempotency_header,
          'amount' => amount,
          'currency' => spec.currency,
          'external_id_field' => spec.external_id_field,
          'status_map' => spec.status_map,
          'error_map' => spec.error_map.transform_keys(&:to_s),
          'recipient' => spec.recipient_spec,
          'required_requisite' => spec.required_requisite,
          'request_payload_ruby' => spec.request_payload_ruby,
          'manual_fields' => spec.report.todos.map { |t| t.to_h.transform_keys(&:to_s) },
          'diagnostics' => spec.report.diagnostics.map { |d| d.to_h.transform_keys(&:to_s) }
        }
      end

      def endpoint(endpoint)
        {
          'method' => endpoint.http_method.upcase,
          'path' => endpoint.path,
          'role' => endpoint.role.to_s,
          'operation_id' => endpoint.operation_id,
          'spec_line' => endpoint.spec_line
        }
      end

      def recognized
        {
          'create' => ref(spec.create_endpoint),
          'status' => ref(spec.status_endpoint),
          'cancel' => ref(spec.cancel_endpoint),
          'webhook' => spec.webhook && "POST #{spec.webhook.path}"
        }
      end

      def ref(endpoint)
        endpoint && "#{endpoint.http_method.upcase} #{endpoint.path}"
      end

      def auth
        return nil unless spec.auth

        {
          'type' => spec.auth.scheme_type,
          'scheme' => spec.auth.http_scheme,
          'location' => spec.auth.location,
          'header' => spec.auth.header_name,
          'credentials_field' => spec.auth.credentials_field,
          'spec_line' => spec.auth.spec_line
        }
      end

      def amount
        return nil unless spec.amount

        {
          'field' => spec.amount[:field],
          'unit' => spec.amount[:minor_units] ? 'minor' : 'major',
          'min_native' => spec.amount[:min_native]
        }
      end
    end
  end
end
