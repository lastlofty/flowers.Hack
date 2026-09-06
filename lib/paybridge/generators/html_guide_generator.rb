# frozen_string_literal: true

require 'cgi'

module Paybridge
  module Generators
    # `<provider>_integration.html` — самодостаточная HTML-инструкция по интеграции
    # (портируемый гайд, который можно открыть в браузере/отдать заказчику): что
    # распознано, авторизация, методы, маппинги статусов/ошибок, webhook, поля для
    # ручного заполнения, диагностика с уровнями и провенанс. Только stdlib.
    #
    # Детерминирован (упорядоченный вывод) — годится для проверки/демо.
    class HtmlGuideGenerator
      attr_reader :spec

      def initialize(spec, **_opts)
        @spec = spec
      end

      def filename
        "#{spec.provider_name}_integration.html"
      end

      def render
        <<~HTML
          <!doctype html><meta charset="utf-8">
          <title>#{e(spec.provider_name)} — интеграция</title>
          #{CSS}
          <h1>#{e(spec.provider_name)} <span class="muted">#{e(spec.title)} v#{e(spec.version)}</span></h1>
          <p class="muted">BASE_URL: <code>#{e(spec.base_url)}</code></p>
          #{auth_section}
          #{endpoints_section}
          #{maps_section}
          #{webhook_section}
          #{manual_section}
          #{diagnostics_section}
          #{provenance_section}
        HTML
      end

      private

      def e(value) = CGI.escapeHTML(value.to_s)

      def auth_section
        return '<h2>Авторизация</h2><p>не требуется</p>' unless spec.auth

        scheme = spec.auth.http_scheme ? " (#{e(spec.auth.http_scheme)})" : ''
        "<h2>Авторизация</h2><p>#{e(spec.auth.scheme_type)}#{scheme} · заголовок " \
          "<code>#{e(spec.auth.header_name)}</code> · credentials.<code>#{e(spec.auth.credentials_field)}</code></p>"
      end

      def endpoints_section
        rows = [
          endpoint_row('Создание', spec.create_endpoint),
          endpoint_row('Статус', spec.status_endpoint),
          endpoint_row('Отмена', spec.cancel_endpoint),
          spec.webhook ? "<tr><td>Webhook</td><td><code>POST #{e(spec.webhook.path)}</code></td></tr>" : nil
        ].compact.join
        idem = spec.idempotency_header ? "<p class=\"muted\">Идемпотентность: <code>#{e(spec.idempotency_header)}</code></p>" : ''
        "<h2>Методы</h2><table><tbody>#{rows}</tbody></table>#{idem}"
      end

      def endpoint_row(label, endpoint)
        return nil unless endpoint

        "<tr><td>#{e(label)}</td><td><code>#{e(endpoint.http_method.upcase)} #{e(endpoint.path)}</code></td></tr>"
      end

      def maps_section
        status = spec.status_map.map { |k, v| "<tr><td><code>#{e(k)}</code></td><td>→ #{e(v)}</td></tr>" }.join
        errors = spec.error_map.map { |k, v| "<tr><td>#{e(k)}</td><td>→ #{e(v)}</td></tr>" }.join
        amount = if spec.amount
                   "<p class=\"muted\">Сумма: поле <code>#{e(spec.amount[:field])}</code>, " \
                     "единица #{spec.amount[:minor_units] ? 'minor' : 'major'}</p>"
                 else
                   ''
                 end
        "<div class=\"two\"><div><h2>Статусы</h2><table><tbody>#{status}</tbody></table></div>" \
          "<div><h2>Ошибки</h2><table><tbody>#{errors}</tbody></table></div></div>#{amount}"
      end

      def webhook_section
        return '' unless spec.webhook

        sig = if spec.webhook.signature_header
                "#{e(spec.webhook.signature_header)} (HMAC-#{e(spec.webhook.signature_alg)}, #{e(spec.webhook.signature_encoding)})"
              else
                'подпись не описана'
              end
        events = Array(spec.webhook.events).map { |ev| "<code>#{e(ev)}</code>" }.join(' ')
        "<h2>Webhook</h2><p>#{e(spec.webhook.path)} · подпись: #{sig}</p><p>#{events}</p>"
      end

      def manual_section
        return '' if spec.report.todos.empty?

        items = spec.report.todos.map do |t|
          "<li><code>#{e(t.field)}</code> <span class=\"muted\">#{e(t.where)}</span><br>" \
            "<span class=\"hint\">#{e(t.hint)}</span></li>"
        end.join
        "<h2 class=\"todo\">✍ Заполните вручную (#{spec.report.todos.size})</h2><ul class=\"todo-list\">#{items}</ul>"
      end

      def diagnostics_section
        by = spec.report.diagnostics_by_level
        return '' if by.empty?

        blocks = %i[error warn info].filter_map do |level|
          msgs = by[level]
          next unless msgs&.any?

          items = msgs.map { |m| "<li>#{e(m)}</li>" }.join
          "<h3 class=\"lvl-#{level}\">#{level} (#{msgs.size})</h3><ul>#{items}</ul>"
        end.join
        "<h2>Диагностика</h2>#{blocks}"
      end

      def provenance_section
        "<hr><p class=\"muted prov\">PayBridge #{e(Paybridge::VERSION)} · spec sha256: " \
          "<code>#{e(spec.spec_sha256)}</code></p>"
      end

      CSS = <<~STYLE
        <style>
          :root{color-scheme:light dark}
          body{font:14px/1.55 system-ui,-apple-system,Segoe UI,sans-serif;max-width:900px;margin:24px auto;padding:0 16px}
          h1{font-size:1.5rem;margin-bottom:2px}h2{font-size:1.05rem;margin:18px 0 6px}
          h3{font-size:.9rem;margin:10px 0 2px}
          .muted{color:#888;font-weight:400}.hint{color:#888;font-size:12px}
          table{border-collapse:collapse;width:100%;margin:4px 0}
          td{padding:4px 8px;border-bottom:1px solid #8883;font-size:13px}
          code{background:#8881;padding:1px 6px;border-radius:5px;font:12px ui-monospace,Menlo,monospace}
          .two{display:flex;gap:24px;flex-wrap:wrap}.two>div{flex:1;min-width:220px}
          .todo{color:#b7791f}.todo-list li{margin:6px 0}
          .lvl-error{color:#d33}.lvl-warn{color:#b7791f}.lvl-info{color:#888}
          .prov{font-size:12px}
        </style>
      STYLE
    end
  end
end
