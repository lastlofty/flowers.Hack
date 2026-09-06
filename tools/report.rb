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
        warnings: gen.warnings, todos: gen.todos || [],
        syntax: syntax_ok?(gen.files["#{provider}_service.rb"]),
        verify: verify(dir) }
    rescue Paybridge::GenerationError => e
      { provider: provider, error: e.message }
    end

    def verify(dir)
      Paybridge::Verifier.new(dir).run
    rescue StandardError => e
      OpenStruct.new(
        passed: 0, failed: 0, skipped: 0, cases: [], error: e.message,
        status: 'error', all_passed?: false
      )
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

    def badge(status, text)
      cls = case status.to_s
            when 'passed' then 'ok'
            when 'partial' then 'warn'
            else 'bad'
            end
      "<span class=\"badge #{cls}\">#{e(text)}</span>"
    end

    def verify_status(report)
      return 'error' if report.respond_to?(:error) && report.error
      return report.status if report.respond_to?(:status)
      return 'failed' if report.failed.positive?
      return 'partial' if report.respond_to?(:skipped) && report.skipped.positive?

      report.passed.positive? ? 'passed' : 'partial'
    end

    def verify_label(report)
      skipped = report.respond_to?(:skipped) ? report.skipped : 0
      "#{report.passed}/#{report.passed + report.failed + skipped}"
    end

    def render(results)
      +CSS + "<h1>PayBridge <span class=\"logo\">— отчёт по интеграциям</span></h1>" \
             "<p class=\"sub\">Сгенерировано #{e(Time.now.strftime('%Y-%m-%d %H:%M'))}</p>" +
        stat_strip(results) + summary_table(results) + results.map { |r| card(r) }.join + '</div>'
    end

    # Верхняя полоса ключевых цифр — чтобы картина читалась за секунду.
    def stat_strip(results)
      ok = results.reject { |r| r[:error] }
      syntax_ok = ok.count { |r| r[:syntax] }
      verify_ok = ok.count { |r| verify_status(r[:verify]) == 'passed' }
      manual = ok.sum { |r| (r[:todos] || []).size }
      warns = ok.sum { |r| r[:warnings].size }
      cells = [
        ['Провайдеров', results.size, 'neutral'],
        ['ruby -c OK', "#{syntax_ok}/#{ok.size}", syntax_ok == ok.size ? 'ok' : 'bad'],
        ['verify passed', "#{verify_ok}/#{ok.size}", verify_ok == ok.size ? 'ok' : 'warn'],
        ['Заполнить вручную', manual, manual.zero? ? 'ok' : 'warn'],
        ['Предупреждений', warns, warns.zero? ? 'ok' : 'warn']
      ]
      chips = cells.map do |label, value, cls|
        "<div class=\"stat #{cls}\"><span class=\"stat-n\">#{e(value)}</span>" \
          "<span class=\"stat-l\">#{e(label)}</span></div>"
      end.join
      "<div class=\"strip\">#{chips}</div>"
    end

    def summary_table(results)
      rows = results.map do |r|
        next "<tr><td>#{e(r[:provider])}</td><td colspan=\"6\" class=\"bad\">Ошибка: #{e(r[:error])}</td></tr>" if r[:error]

        m = r[:model]
        manual = (r[:todos] || []).size
        manual_cell = manual.zero? ? '<td class="ok">—</td>' : "<td>#{badge('partial', "#{manual} ✍")}</td>"
        "<tr>" \
          "<td><b>#{e(r[:provider])}</b></td>" \
          "<td>#{m[:endpoints].size}</td>" \
          "<td>#{e(m.dig(:auth, :type) || '—')}</td>" \
          "<td>#{badge(r[:syntax] ? 'passed' : 'failed', r[:syntax] ? 'Syntax OK' : 'ошибка')}</td>" \
          "<td>#{badge(verify_status(r[:verify]), "#{verify_status(r[:verify])} #{verify_label(r[:verify])}")}</td>" \
          "#{manual_cell}" \
          "<td>#{r[:warnings].size}</td>" \
          "</tr>"
      end.join
      "<table class=\"summary\"><thead><tr><th>Провайдер</th><th>Методов</th><th>Auth</th>" \
        "<th>ruby -c</th><th>verify</th><th>Вручную</th><th>Предупр.</th></tr></thead><tbody>#{rows}</tbody></table>" \
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
        manual_html(r[:todos] || []) + files_html(r[:files]) + warnings_html(r[:warnings]) +
        '</section>'
    end

    # Действенный блок: поля, которые провайдер требует, но их нельзя вывести
    # из спеки — их заполняет разработчик. Показываем чек-листом с подсказкой.
    def manual_html(todos)
      return '' if todos.empty?

      items = todos.map do |t|
        "<li><label><input type=\"checkbox\"> <code>#{e(t[:field])}</code> " \
          "<span class=\"muted\">#{e(t[:where])}</span></label>" \
          "<div class=\"hint\">#{e(t[:hint])}</div></li>"
      end.join
      "<div class=\"manual\"><h3>✍ Заполните вручную (#{todos.size})</h3>" \
        "<p class=\"muted\">В коде эти поля помечены <code>TODO(PayBridge)</code> и отправляются как <code>nil</code>, пока не заполнены.</p>" \
        "<ul class=\"todo-list\">#{items}</ul></div>"
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
      skipped = v.respond_to?(:skipped) ? v.skipped : 0
      error = v.respond_to?(:error) && v.error ? "<p class=\"bad\">#{e(v.error)}</p>" : ''
      "<h3>Verify: #{e(verify_status(v))} · #{v.passed} passed, #{v.failed} failed, #{skipped} skipped</h3>" \
        "#{error}<ul class=\"cases\">#{cases}</ul>"
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
        :root{color-scheme:light dark;--line:#8883;--muted:#888;--ok:#17803d;--warn:#b7791f;--bad:#d33;--accent:#3b5bdb}
        *{box-sizing:border-box}
        body{font:14px/1.55 system-ui,-apple-system,Segoe UI,sans-serif;max-width:1040px;margin:0 auto;padding:28px 16px 64px}
        h1{font-size:1.6rem;margin:0 0 2px;letter-spacing:-.01em}
        h1 .logo{color:var(--muted);font-weight:400}
        .sub{color:var(--muted);margin:0 0 18px}
        table{border-collapse:collapse;width:100%;margin:6px 0}
        th,td{text-align:left;padding:6px 10px;border-bottom:1px solid var(--line);font-size:13px}
        .summary{border:1px solid var(--line);border-radius:12px;overflow:hidden}
        .summary th{background:#8881;position:sticky;top:0;font-size:12px;text-transform:uppercase;letter-spacing:.03em;color:var(--muted)}
        .summary tbody tr:hover{background:#8881}
        /* верхняя полоса цифр */
        .strip{display:flex;gap:12px;flex-wrap:wrap;margin:0 0 18px}
        .stat{flex:1;min-width:130px;border:1px solid var(--line);border-radius:12px;padding:12px 14px;display:flex;flex-direction:column;gap:2px}
        .stat-n{font-size:1.5rem;font-weight:700;line-height:1}
        .stat-l{font-size:12px;color:var(--muted)}
        .stat.ok .stat-n{color:var(--ok)}.stat.warn .stat-n{color:var(--warn)}.stat.bad .stat-n{color:var(--bad)}
        .cards{margin-top:8px}
        .card{border:1px solid var(--line);border-radius:14px;padding:16px 20px;margin:16px 0;box-shadow:0 1px 3px #0000000d}
        .card h2{font-size:1.2rem;margin:0 0 4px}
        .muted{color:var(--muted);font-weight:400;font-size:.9em}
        h3{font-size:.95rem;margin:14px 0 4px}
        .two{display:flex;gap:24px;flex-wrap:wrap}.two>div{flex:1;min-width:220px}
        .badge{padding:2px 9px;border-radius:20px;font-size:12px;font-weight:600;white-space:nowrap}
        .badge.ok{background:#17803d22;color:var(--ok)}.badge.warn{background:#b7791f22;color:var(--warn)}.badge.bad{background:#d3333322;color:var(--bad)}
        code{background:#8881;padding:1px 6px;border-radius:5px;font:12px ui-monospace,SFMono-Regular,Menlo,monospace}
        .ok{color:var(--ok)}.bad{color:var(--bad)}.warn{color:var(--warn)}
        ul.cases{list-style:none;padding:0;columns:2;margin:4px 0}ul.cases li{font-size:12px;break-inside:avoid}
        .warn-list li{color:var(--warn);font-size:13px}
        /* блок ручного заполнения — действенный акцент */
        .manual{border-left:3px solid var(--warn);background:#b7791f0f;border-radius:8px;padding:8px 14px;margin:12px 0}
        .manual h3{margin-top:4px;color:var(--warn)}
        .todo-list{list-style:none;padding:0;margin:6px 0}
        .todo-list li{padding:6px 0;border-top:1px solid var(--line)}
        .todo-list li:first-child{border-top:0}
        .todo-list label{font-weight:600;cursor:pointer}
        .hint{color:var(--muted);font-size:12px;margin:2px 0 0 22px}
      </style>
    HTML
  end
end

require 'ostruct'
