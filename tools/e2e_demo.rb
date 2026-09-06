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

mock = Paybridge::MockProvider.new(spec, created_status: 'pending', final_status: 'completed').start
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

fake_provider = Struct.new(:credentials).new({ 'api_key' => 'live_key', 'callback_secret' => 'test_secret' })
operation = Struct.new(:amount, :id, :payout_requisite, :provider_operation_id, :idempotency_key, keyword_init: true).new(
  amount: 15_000, id: 'op1',
  payout_requisite: { 'sbp' => { 'phone' => '79001234567', 'bank_code' => '044525225', 'bank_name' => 'Bank' } },
  provider_operation_id: 'srv_1', idempotency_key: 'idem1'
)
service = klass.new(provider: fake_provider)

puts '1) create_request -> реальный POST к провайдеру'
r1 = service.create_request(operation)
puts "   результат: #{r1.status} / #{r1.data.inspect}"
puts "   провайдер получил: #{mock.requests.last[:method]} #{mock.requests.last[:path]} (auth=#{mock.requests.last[:auth]})\n\n"

if spec.status_endpoint
  puts '2) fetch_status -> реальный GET к провайдеру'
  r2 = service.fetch_status(operation)
  puts "   результат: #{r2.status} / #{r2.data.inspect}"
  puts "   провайдер получил: #{mock.requests.last[:method]} #{mock.requests.last[:path]}\n\n"
end

if spec.webhook
  puts '3) webhook -> провайдер шлёт подписанное уведомление'
  raw, sig = mock.webhook_message({ 'event' => spec.webhook.events.first, 'payout_id' => 'srv_1', 'status' => 'completed' })
  r3 = service.process_callback(raw, sig)
  puts "   результат: #{r3.status} / #{r3.data.inspect}"
  puts '   подделка тела с той же подписью:'
  begin
    service.process_callback(raw.sub('completed', 'failed'), sig)
    puts '   ПРИНЯТО (плохо!)'
  rescue Provider::UnauthorizedError
    puts '   ОТКЛОНЕНО подписью ✅'
  end
end

mock.stop
puts "\nГотово: сгенерированная интеграция отработала полный цикл по реальному HTTP."
