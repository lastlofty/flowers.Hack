# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require_relative '../lib/paybridge'

# P#3: выбор способа выплаты (sbp/card) через request_method — сгенерированный
# сервис строит recipient нужного способа и валидирует его обязательные поля.
class TestMethodSelection < Minitest::Test
  PROVIDER = 'methodsel'

  # Клиент, перехватывающий тело запроса (без реальной сети).
  class Capture
    attr_reader :json

    def post(_url, json:, headers: {})
      @json = json
      Provider::HttpClient::Response.new(status: 201, body: { 'id' => 'x', 'status' => 'pending' })
    end

    def get(*_args, **_kw)
      Provider::HttpClient::Response.new(status: 200, body: { 'status' => 'completed' })
    end
  end

  def self.klass
    @klass ||= begin
      spec_path = File.expand_path('../examples/provider_api.yaml', __dir__)
      gen = Paybridge.generate(spec_path: spec_path, provider: PROVIDER)
      dir = Dir.mktmpdir('pb_method_')
      File.write(File.join(dir, "#{PROVIDER}_service.rb"), gen.files["#{PROVIDER}_service.rb"])
      FileUtils.cp(Paybridge::BASE_SERVICE, File.join(dir, 'base_service.rb'))
      require File.join(dir, 'base_service.rb') unless defined?(Provider::BaseService)
      require File.join(dir, "#{PROVIDER}_service.rb") unless Provider.const_defined?(:MethodselService, false)
      Provider::MethodselService
    end
  end

  def service(capture)
    svc = self.class.klass.new(provider: Struct.new(:credentials).new({ 'api_key' => 'k' }))
    svc.instance_variable_set(:@client, capture)
    svc
  end

  def op(requisite)
    Struct.new(:amount, :id, :payout_requisite, :provider_operation_id, :idempotency_key,
               keyword_init: true).new(
      amount: 15_000, id: 'op1', payout_requisite: requisite,
      provider_operation_id: 'srv_1', idempotency_key: 'idem1'
    )
  end

  SBP  = { 'sbp'  => { 'phone' => '79001234567', 'bank_code' => '044525225', 'bank_name' => 'Bank' } }.freeze
  CARD = { 'card' => { 'phone' => '79001234567', 'card_number' => '4111111111111111' } }.freeze

  def test_card_method_builds_card_recipient
    cap = Capture.new
    service(cap).create_request(op(CARD), 'card')
    r = cap.json[:recipient]
    assert_equal 'card', r[:type]
    assert_equal '4111111111111111', r[:card_number]
    refute r.key?(:bank_code), 'card-получатель не должен содержать bank_code'
  end

  def test_sbp_method_builds_sbp_recipient
    cap = Capture.new
    service(cap).create_request(op(SBP), 'sbp')
    r = cap.json[:recipient]
    assert_equal 'sbp', r[:type]
    assert_equal '044525225', r[:bank_code]
    refute r.key?(:card_number), 'sbp-получатель не должен содержать card_number'
  end

  def test_method_detected_from_requisite
    cap = Capture.new
    # request_method='create' (не способ) -> определяем по наличию реквизитов
    service(cap).create_request(op(CARD))
    assert_equal 'card', cap.json[:recipient][:type]
  end

  def test_card_request_not_turned_into_sbp
    cap = Capture.new
    service(cap).create_request(op(CARD), 'card')
    refute_equal 'sbp', cap.json[:recipient][:type]
  end

  def test_missing_card_number_rejected
    result = service(Capture.new).check_conditions(op('card' => { 'phone' => '79001234567' }), 'card')
    assert result.failed?
    assert_equal 'missing_requisite', result.message
  end

  def test_full_card_requisite_passes_conditions
    result = service(Capture.new).check_conditions(op(CARD), 'card')
    assert result.success?, result.message
  end
end
