# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require_relative '../lib/paybridge'
require_relative '../tools/mock_provider'

# Сквозной e2e: сгенерированный сервис ходит к мок-провайдеру РЕАЛЬНЫМ net/http.
# Доказывает, что интеграция работает целиком по проводам (create/status), а не
# только через мок-клиент; webhook проверяется подписанным payload.
#
# BASE_URL сервиса фиксируется при require из ENV, поэтому мок и require — ОДИН раз
# на весь класс (общий порт), а запросы чистим перед каждым тестом.
class TestE2E < Minitest::Test
  # Уникальное имя провайдера, чтобы класс сервиса (и его BASE_URL) не пересекался
  # с Provider::NovapayService из других тестов (иначе require-guard подхватит чужой).
  PROVIDER = 'e2eflow'

  def self.harness
    @harness ||= begin
      spec_path = File.expand_path('../examples/provider_api.yaml', __dir__)
      spec = Paybridge::SpecParser.new(spec_path, PROVIDER, Paybridge.load_config).parse
      mock = Paybridge::MockProvider.new(spec, created_status: 'pending', final_status: 'completed').start
      ENV['E2EFLOW_BASE_URL'] = mock.base_url

      dir = Dir.mktmpdir('pb_e2e_')
      gen = Paybridge.generate(spec_path: spec_path, provider: PROVIDER)
      File.write(File.join(dir, "#{PROVIDER}_service.rb"), gen.files["#{PROVIDER}_service.rb"])
      FileUtils.cp(Paybridge::BASE_SERVICE, File.join(dir, 'base_service.rb'))
      require File.join(dir, 'base_service.rb') unless defined?(Provider::BaseService)
      require File.join(dir, "#{PROVIDER}_service.rb") unless Provider.const_defined?(:E2eflowService, false)

      Minitest.after_run { mock.stop }
      { mock: mock, klass: Provider::E2eflowService }
    end
  end

  def setup
    @h = self.class.harness
    @h[:mock].requests.clear
    @service = @h[:klass].new(provider: provider)
  end

  def provider
    Struct.new(:credentials).new({ 'api_key' => 'test_key', 'callback_secret' => 'test_secret' })
  end

  def operation
    Struct.new(:amount, :id, :payout_requisite, :provider_operation_id, :idempotency_key,
               keyword_init: true).new(
      amount: 15_000, id: 'op1',
      payout_requisite: { 'sbp' => { 'phone' => '79001234567', 'bank_code' => '044525225', 'bank_name' => 'Bank' } },
      provider_operation_id: 'srv_1', idempotency_key: 'idem1'
    )
  end

  def test_create_over_real_http
    result = @service.create_request(operation)
    assert result.success?, "create failed: #{result.message}"
    assert_equal 'in_progress', result.data[:status].to_s
    assert_equal 'srv_1', result.data[:provider_operation_id].to_s

    posted = @h[:mock].requests.find { |r| r[:method] == 'POST' }
    refute_nil posted, 'мок не получил POST'
    assert_equal '/payouts', posted[:path]
    assert_equal 'test_key', posted[:auth], 'сервис не отправил ключ авторизации'
    assert_equal 'idem1', posted[:idempotency], 'сервис не отправил Idempotency-Key'
    assert_includes posted[:body], '1500000', 'сумма не в копейках в теле запроса'
  end

  def test_fetch_status_over_real_http
    result = @service.fetch_status(operation)
    assert result.success?, "status failed: #{result.message}"
    assert_equal 'approved', result.data[:status].to_s

    got = @h[:mock].requests.find { |r| r[:method] == 'GET' }
    refute_nil got, 'мок не получил GET'
    assert_equal '/payouts/srv_1', got[:path]
  end

  def test_signed_webhook_processed
    raw, sig = @h[:mock].webhook_message({ 'event' => 'payout.completed', 'payout_id' => 'srv_1', 'status' => 'completed' })
    result = @service.process_callback(raw, sig)
    assert result.success?, "callback failed: #{result.message}"
    assert_equal 'approved', result.data[:status].to_s
  end

  def test_webhook_rejects_tampered_body
    raw, sig = @h[:mock].webhook_message({ 'event' => 'payout.completed', 'payout_id' => 'srv_1', 'status' => 'completed' })
    tampered = raw.sub('completed', 'failed') # тело изменено, подпись прежняя
    assert_raises(Provider::UnauthorizedError) { @service.process_callback(tampered, sig) }
  end

  def test_full_flow_create_status_webhook
    assert @service.create_request(operation).success?
    assert @service.fetch_status(operation).success?
    raw, sig = @h[:mock].webhook_message({ 'event' => 'payout.completed', 'payout_id' => 'srv_1', 'status' => 'completed' })
    assert @service.process_callback(raw, sig).success?
    assert(@h[:mock].requests.any? { |r| r[:method] == 'POST' })
    assert(@h[:mock].requests.any? { |r| r[:method] == 'GET' })
  end
end
