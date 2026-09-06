# frozen_string_literal: true

# Живая e2e-демонстрация: генерируем сервис, поднимаем мок-провайдера и гоняем
# сгенерированный код против него ПО РЕАЛЬНОМУ HTTP (create -> status -> webhook).
#
# Запуск:  ruby tools/e2e_demo.rb [examples/provider_api.yaml] [novapay]
require_relative '../lib/paybridge'
require_relative 'mock_provider'
require 'tmpdir'
require 'fileutils'

spec_path = ARGV[0] || File.expand_path('../examples/provider_api.yaml', __dir__)
provider  = ARGV[1] || 'novapay'

config = Paybridge.load_config
spec = Paybridge::SpecParser.new(spec_path, provider, config).parse
created_status = spec.status_map.key('in_progress') || spec.status_map.keys.first
final_status = spec.status_map.key('approved') || created_status
abort 'Спецификация не содержит распознаваемых статусов для E2E' unless created_status

mock = Paybridge::MockProvider.new(spec, created_status: created_status, final_status: final_status).start
at_exit { mock.stop }
ENV["#{provider.upcase}_BASE_URL"] = mock.base_url
puts "Мок-провайдер поднят: #{mock.base_url}"

dir = Dir.mktmpdir("pb_demo_#{provider}_")
gen = Paybridge.generate(spec_path: spec_path, provider: provider)
File.write(File.join(dir, "#{provider}_service.rb"), gen.files["#{provider}_service.rb"])
FileUtils.cp(Paybridge::BASE_SERVICE, File.join(dir, 'base_service.rb'))
require File.join(dir, 'base_service.rb')
require File.join(dir, "#{provider}_service.rb")
klass = Provider.const_get(Paybridge::Safe.class_name(provider))
puts "Сгенерирован и загружен сервис: Provider::#{klass.name.split('::').last}\n\n"

credentials = {
  'api_key' => 'live_key', 'token' => 'live_token', 'username' => 'live_user',
  'password' => 'live_password', 'callback_secret' => 'test_secret'
}
fake_provider = Struct.new(:credentials).new(credentials)
operation_class = Struct.new(
  :amount, :id, :payout_requisite, :provider_operation_id, :idempotency_key,
  keyword_init: true
)
operation = operation_class.new(
  amount: 15_000, id: 'op1',
  payout_requisite: { 'sbp' => { 'phone' => '79001234567', 'bank_code' => '044525225', 'bank_name' => 'Bank' } },
  provider_operation_id: 'srv_1', idempotency_key: 'idem1'
)
service = klass.new(provider: fake_provider)

puts '1) create_request -> реальный POST к провайдеру'
r1 = service.create_request(operation)
puts "   результат: #{r1.status} / #{r1.data.inspect}"
request = mock.requests.last
puts "   провайдер получил: #{request[:method]} #{request[:path]} (auth=#{request[:auth]})\n\n"
raise "create_request завершился ошибкой: #{r1.message}" unless r1.success?

if spec.status_endpoint
  puts '2) fetch_status -> реальный GET к провайдеру'
  r2 = service.fetch_status(operation)
  puts "   результат: #{r2.status} / #{r2.data.inspect}"
  puts "   провайдер получил: #{mock.requests.last[:method]} #{mock.requests.last[:path]}\n\n"
  raise "fetch_status завершился ошибкой: #{r2.message}" unless r2.success?
end

if spec.webhook
  puts '3) webhook -> провайдер шлёт подписанное уведомление'
  event, action = spec.webhook.event_actions.find { |_name, value| %i[approve reject].include?(value) }
  raise 'Webhook не содержит события с понятным действием approve/reject' unless event

  callback_status = spec.status_map.key(action == :approve ? 'approved' : 'rejected') || final_status
  raw, sig = mock.webhook_message({ 'event' => event, spec.webhook.id_field => 'srv_1', 'status' => callback_status })
  r3 = service.process_callback(raw, sig)
  puts "   результат: #{r3.status} / #{r3.data.inspect}"
  callback_ok = action == :approve ? r3.success? : r3.failed? && r3.code == :rejected
  raise "process_callback вернул неожиданный результат: #{r3.message}" unless callback_ok

  if spec.webhook.signature_header
    puts '   подделка тела с той же подписью:'
    begin
      tampered = raw.sub(/"status":"[^"]+"/, '"status":"tampered"')
      raise 'не удалось изменить тело для negative-сценария' if tampered == raw

      service.process_callback(tampered, sig)
      raise 'изменённое тело было принято с прежней подписью'
    rescue Provider::UnauthorizedError
      puts '   ОТКЛОНЕНО подписью ✅'
    end
  else
    puts '   проверка подмены пропущена: спецификация не описывает подпись webhook'
  end
end

mock.stop
puts "\nГотово: отработали все поддерживаемые спецификацией этапы по реальному HTTP."
