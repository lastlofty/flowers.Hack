# frozen_string_literal: true

module Paybridge
  module Generators
    # SAFETY.md — аудит платёжных рисков сгенерированной интеграции: подпись
    # webhook, авторизация, идемпотентность, единица суммы, TLS, поля для ручного
    # заполнения, диагностика. Каждый пункт — статус (ok/внимание/риск) и что
    # проверить перед боем. Итоговый вердикт о готовности.
    class SafetyGenerator
      OK = '✅'
      WARN = '⚠️'
      RISK = '❗'

      attr_reader :spec

      def initialize(spec, **_opts)
        @spec = spec
      end

      def filename
        'SAFETY.md'
      end

      def render
        checks = build_checks
        verdict = overall(checks)
        <<~MD
          # Аудит безопасности — #{spec.provider_name}

          Автоматический разбор платёжных рисков интеграции. Провенанс: PayBridge
          #{Paybridge::VERSION}, spec sha256 `#{spec.spec_sha256}`.

          **Вердикт: #{verdict}**

          | Проверка | Статус | Комментарий |
          |---|:--:|---|
          #{checks.map { |c| "| #{c[:name]} | #{c[:status]} | #{c[:note]} |" }.join("\n")}

          #{manual_section}
          > Аудит опирается на структуру спецификации. Пункты со статусом
          > #{WARN}/#{RISK} требуют ручной проверки перед продакшеном.
        MD
      end

      private

      def build_checks
        [signature_check, tls_check, auth_check, idempotency_check, amount_check, diagnostics_check].compact
      end

      def signature_check
        if spec.webhook.nil?
          { name: 'Подпись webhook', status: OK, note: 'webhook в спеке нет — проверять нечего' }
        elsif spec.webhook.signature_header
          { name: 'Подпись webhook', status: OK,
            note: "HMAC-#{spec.webhook.signature_alg} по `#{spec.webhook.signature_header}` " \
                  "(#{spec.webhook.signature_encoding}); проверяется по сырому телу" }
        else
          { name: 'Подпись webhook', status: RISK,
            note: 'спека НЕ описывает подпись — верификация не генерируется, ' \
                  'настройте вручную (иначе подделка уведомлений)' }
        end
      end

      def tls_check
        https = spec.base_url.to_s.start_with?('https://')
        { name: 'TLS (HTTPS)', status: https ? OK : RISK,
          note: https ? "BASE_URL по https" : "BASE_URL не https (`#{spec.base_url}`) — трафик незащищён" }
      end

      def auth_check
        if spec.auth.nil?
          { name: 'Авторизация', status: RISK,
            note: 'схема не определена — заголовки пустые; задайте overrides.security_scheme' }
        else
          { name: 'Авторизация', status: OK,
            note: "#{spec.auth.scheme_type}#{spec.auth.http_scheme ? "/#{spec.auth.http_scheme}" : ''} " \
                  "через `#{spec.auth.header_name}`" }
        end
      end

      def idempotency_check
        if spec.idempotency_header
          { name: 'Идемпотентность', status: OK, note: "заголовок `#{spec.idempotency_header}` на создании" }
        else
          { name: 'Идемпотентность', status: WARN,
            note: 'спека не описывает ключ идемпотентности — риск двойных списаний при повторе' }
        end
      end

      def amount_check
        return { name: 'Сумма', status: WARN, note: 'поле суммы не распознано' } unless spec.amount

        unit = spec.amount[:minor_units] ? 'minor (копейки/центы)' : 'major (рубли/у.е.)'
        { name: 'Сумма', status: OK, note: "единица: #{unit}; поле `#{spec.amount[:field]}`" }
      end

      def diagnostics_check
        by = spec.report.diagnostics_by_level
        errors = (by[:error] || []).size
        return { name: 'Диагностика', status: RISK, note: "#{errors} ошибок разбора — сервис неполный" } if errors.positive?

        warns = (by[:warn] || []).size
        status = warns.positive? ? WARN : OK
        { name: 'Диагностика', status: status, note: "#{warns} предупреждений, #{(by[:info] || []).size} info" }
      end

      def manual_section
        return '' if spec.report.todos.empty?

        rows = spec.report.todos.map do |t|
          loc = t.line ? " (спека, строка #{t.line})" : ''
          "- `#{t.field}`#{loc} — #{t.hint}"
        end.join("\n")
        "## Поля, требующие ручного заполнения (#{spec.report.todos.size})\n\n" \
          "Провайдер требует эти поля, но их нельзя вывести из модели операции. " \
          "Отправляются как `nil`, пока не заполнены:\n\n#{rows}\n"
      end

      def overall(checks)
        return "#{RISK} НЕ готово — есть критические риски" if checks.any? { |c| c[:status] == RISK }
        return "#{WARN} Требует внимания" if checks.any? { |c| c[:status] == WARN } || spec.report.todos.any?

        "#{OK} Готово к настройке"
      end
    end
  end
end
