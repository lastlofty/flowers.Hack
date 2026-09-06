# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'
require 'rbconfig'
require 'tempfile'
require 'cgi'
require_relative '../lib/paybridge'

module Paybridge
  # Строит единый самодостаточный HTML-отчёт по интеграциям: что распознано,
  # что сгенерировано, компилируется ли (ruby -c), проходит ли verify, какие
  # честные предупреждения. Для наглядной демонстрации (одна страница).
  module HtmlReport
    module_function

    def build(entries)
      render(entries.map { |e| analyze(e[:spec], e[:provider]) })
    end

    def analyze(spec_path, provider)
      model = Paybridge.parse_only(spec_path: spec_path, provider: provider)
      gen   = Paybridge.generate(spec_path: spec_path, provider: provider)

      dir = Dir.mktmpdir("pb_report_#{provider}_")
      gen.files.each { |name, body| File.write(File.join(dir, name), body) }
      FileUtils.cp(Paybridge::BASE_SERVICE, File.join(dir, 'base_service.rb'))

      { provider: provider, model: model, files: gen.files.keys.sort,
        warnings: gen.warnings, syntax: syntax_ok?(gen.files["#{provider}_service.rb"]),
        verify: verify(dir) }
    rescue Paybridge::GenerationError => e
      { provider: provider, error: e.message }
    end

    def verify(dir)
      Paybridge::Verifier.new(dir).run
    rescue StandardError => e
      OpenStruct.new(passed: 0, failed: 0, cases: [], error: e.message)
    end

    def syntax_ok?(code)
      file = Tempfile.new(['svc', '.rb'])
      file.write(code)
      file.rewind
      out = `"#{RbConfig.ruby}" -c "#{file.path}" 2>&1`
      file.close!
      out.include?('Syntax OK')
    end

    # --- рендер ----------------------------------------------------------

    def e(value)
      CGI.escapeHTML(value.to_s)
    end

    def badge(ok, text)
      cls = ok ? 'ok' : 'bad'
      "<span class=\"badge #{cls}\">#{e(text)}</span>"
    end

    def render(results)
      +CSS + "<h1>PayBridge — отчёт по интеграциям</h1>" \
             "<p class=\"sub\">Сгенерировано #{e(Time.now.strftime('%Y-%m-%d %H:%M'))} · провайдеров: #{results.size}</p>" +
        summary_table(results) + results.map { |r| card(r) }.join + '</div>'
    end

    def summary_table(results)
      rows = results.map do |r|
        next "<tr><td>#{e(r[:provider])}</td><td colspan=\"5\" class=\"bad\">Ошибка: #{e(r[:error])}</td></tr>" if r[:error]

        m = r[:model]
        "<tr>" \
          "<td><b>#{e(r[:provider])}</b></td>" \
          "<td>#{m[:endpoints].size}</td>" \
          "<td>#{e(m.dig(:auth, :type) || '—')}</td>" \
          "<td>#{badge(r[:syntax], r[:syntax] ? 'Syntax OK' : 'ошибка')}</td>" \
          "<td>#{badge(r[:verify].failed.zero?, "#{r[:verify].passed}/#{r[:verify].passed + r[:verify].failed}")}</td>" \
          "<td>#{r[:warnings].size}</td>" \
          "</tr>"
      end.join
      "<table class=\"summary\"><thead><tr><th>Провайдер</th><th>Методов</th><th>Auth</th>" \
        "<th>ruby -c</th><th>verify</th><th>Предупр.</th></tr></thead><tbody>#{rows}</tbody></table>" \
        '<div class="cards">'
    end

    def card(r)
      return "<section class=\"card\"><h2>#{e(r[:provider])}</h2><p class=\"bad\">Ошибка генерации: #{e(r[:error])}</p></section>" if r[:error]

      m = r[:model]
      "<section class=\"card\">" \
        "<h2>#{e(r[:provider])} <span class=\"muted\">#{e(m[:title])} v#{e(m[:version])}</span></h2>" \
        "<p class=\"muted\">BASE_URL: #{e(m[:base_url])} · Auth: #{e(m.dig(:auth, :type) || '—')} " \
        "(#{e(m.dig(:auth, :header) || '—')})</p>" +
        endpoints_html(m) + maps_html(m) + webhook_html(m) + verify_html(r[:verify]) +
        files_html(r[:files]) + warnings_html(r[:warnings]) +
        '</section>'
    end

    def endpoints_html(m)
      rows = m[:endpoints].first(40).map { |ep| "<tr><td>#{e(ep[:method])}</td><td>#{e(ep[:path])}</td><td class=\"muted\">#{e(ep[:role])}</td></tr>" }.join
      more = m[:endpoints].size > 40 ? "<p class=\"muted\">…и ещё #{m[:endpoints].size - 40}</p>" : ''
      "<h3>Методы (#{m[:endpoints].size})</h3><table><tbody>#{rows}</tbody></table>#{more}"
    end

    def maps_html(m)
      st = m[:status_map].map { |k, v| "<tr><td>#{e(k)}</td><td>→ #{e(v)}</td></tr>" }.join
      er = m[:error_map].map { |k, v| "<tr><td>#{e(k)}</td><td>→ #{e(v)}</td></tr>" }.join
      "<div class=\"two\"><div><h3>Статусы</h3><table><tbody>#{st}</tbody></table></div>" \
        "<div><h3>Ошибки</h3><table><tbody>#{er}</tbody></table></div></div>"
    end

    def webhook_html(m)
      return '' unless m[:webhook]

      w = m[:webhook]
      sig = w[:signature_header] ? "#{e(w[:signature_header])} (HMAC-#{e(w[:signature_alg])})" : 'нет подписи'
      "<h3>Webhook</h3><p>#{e(w[:path])} · события: #{e(w[:events].join(', '))} · подпись: #{sig}</p>"
    end

    def verify_html(v)
      cases = v.cases.map do |c|
        cls = c.status == 'passed' ? 'ok' : (c.status == 'skipped' ? 'warn' : 'bad')
        "<li class=\"#{cls}\">#{e(c.status.upcase)} — #{e(c.name)}</li>"
      end.join
      "<h3>Verify: #{v.passed} passed, #{v.failed} failed</h3><ul class=\"cases\">#{cases}</ul>"
    end

    def files_html(files)
      "<h3>Артефакты</h3><p>#{files.map { |f| "<code>#{e(f)}</code>" }.join(' ')}</p>"
    end

    def warnings_html(warnings)
      return '<h3>Предупреждения</h3><p class="ok">нет — всё распознано</p>' if warnings.empty?

      items = warnings.map { |w| "<li>#{e(w)}</li>" }.join
      "<h3>Предупреждения (#{warnings.size}) — честные границы</h3><ul class=\"warn-list\">#{items}</ul>"
    end

    CSS = <<~HTML
      <!doctype html><meta charset="utf-8"><title>PayBridge — отчёт</title>
      <style>
        :root{color-scheme:light dark}
        body{font:14px/1.5 system-ui,sans-serif;max-width:1000px;margin:24px auto;padding:0 16px}
        h1{font-size:1.5rem;margin-bottom:2px}.sub{color:#888;margin-top:0}
        table{border-collapse:collapse;width:100%;margin:6px 0}
        th,td{text-align:left;padding:4px 8px;border-bottom:1px solid #8883;font-size:13px}
        .summary th{background:#8881}
        .card{border:1px solid #8883;border-radius:10px;padding:14px 18px;margin:14px 0}
        .card h2{font-size:1.15rem;margin:0 0 4px}.muted{color:#888;font-weight:400;font-size:.9em}
        h3{font-size:.95rem;margin:12px 0 4px}
        .two{display:flex;gap:24px;flex-wrap:wrap}.two>div{flex:1;min-width:220px}
        .badge{padding:1px 8px;border-radius:10px;font-size:12px;font-weight:600}
        .badge.ok{background:#17803d22;color:#17803d}.badge.bad{background:#d3333322;color:#d33}
        code{background:#8881;padding:1px 6px;border-radius:5px;font-size:12px}
        .ok{color:#17803d}.bad{color:#d33}.warn{color:#b7791f}
        ul.cases{list-style:none;padding:0;columns:2}ul.cases li{font-size:12px}
        .warn-list li{color:#b7791f;font-size:13px}
      </style>
    HTML
  end
end

require 'ostruct'
