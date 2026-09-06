# frozen_string_literal: true

# Одна команда — весь конвейер по всем провайдерам: parse -> generate -> ruby -c ->
# verify, с итоговой таблицей в терминале и самодостаточным HTML-отчётом.
#
# Запуск:  ruby tools/demo.rb   (или rake demo)
$VERBOSE = nil # заглушаем warning'и о переопределении констант (много копий base_service)
require_relative 'report'

providers = [
  { spec: 'examples/provider_api.yaml', provider: 'novapay' },
  { spec: 'examples/bluepay_api.yaml',  provider: 'bluepay' },
  { spec: 'examples/swiftpay_api.yaml', provider: 'swiftpay' },
  { spec: 'examples/europay_api.yaml',  provider: 'europay' },
  { spec: 'examples/manualpay_api.yaml', provider: 'manualpay' }
]
# Реальные боевые спеки (официальные источники) — если скачаны локально.
real = {
  'yookassa' => 'examples/real/yookassa.yaml',
  'adyen'    => 'examples/real/adyen_checkout.yaml',
  'klarna'   => 'examples/real/klarna_payments.yaml',
  'stripe'   => 'examples/real/stripe.yaml'
}
real.each { |provider, spec| providers << { spec: spec, provider: provider } if File.exist?(spec) }

results = providers.map { |e| Paybridge::HtmlReport.analyze(e[:spec], e[:provider]) }

puts
printf "%-10s %8s  %-8s  %-8s  %-15s  %s\n", 'провайдер', 'методов', 'auth', 'ruby -c', 'verify', 'предупр'
puts '-' * 62
results.each do |r|
  if r[:error]
    printf "%-10s  ОШИБКА: %s\n", r[:provider], r[:error]
    next
  end
  m = r[:model]
  printf "%-10s %8d  %-8s  %-8s  %-9s  %d\n",
         r[:provider], m[:endpoints].size, (m.dig(:auth, :type) || '—'),
         (r[:syntax] ? 'OK' : 'FAIL'),
         "#{Paybridge::HtmlReport.verify_status(r[:verify])} #{Paybridge::HtmlReport.verify_label(r[:verify])}",
         r[:warnings].size
end

File.write('demo_report.html', Paybridge::HtmlReport.render(results))
puts
puts 'HTML-отчёт: demo_report.html'

failed = results.any? do |r|
  r[:error] || !r[:syntax] || Paybridge::HtmlReport.verify_status(r[:verify]) != 'passed'
end
exit(failed ? 1 : 0)
