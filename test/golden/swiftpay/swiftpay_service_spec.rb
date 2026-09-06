# frozen_string_literal: true

# СГЕНЕРИРОВАНО PayBridge. Исполняемые контрактные тесты интеграции.
require 'base64'
require 'json'
require 'minitest/autorun'
require 'openssl'
require 'uri'
require_relative 'base_service'
require_relative 'swiftpay_service'

class SwiftpayServiceTest < Minitest::Test
  FIXTURES = JSON.parse(File.read(File.join(__dir__, 'fixtures.json'))).freeze
  CREATE_SUCCESS_CODES = [201].freeze

  class MockClient
    attr_reader :requests

    def initialize(status, body)
      @response = Provider::HttpClient::Response.new(status: status, body: body)
      @requests = []
    end

    def post(url, json: nil, headers: {})
      @requests << { method: 'POST', url: url, headers: headers, json: json }
      @response
    end

    def get(url, headers: {})
      @requests << { method: 'GET', url: url, headers: headers, json: nil }
      @response
    end
  end

  def provider
    Struct.new(:credentials).new({
      'api_key' => 'test_key', 'token' => 'test_token', 'callback_secret' => 'test_secret',
      'username' => 'u', 'password' => 'p'
    })
  end

  def requisite(recipient = nil)
    req = Hash.new { |hash, group| hash[group] = Hash.new { |_nested, field| "test_#{field}" } }
    req['sbp'] = { 'phone' => '79001234567', 'bank_code' => '044525225', 'bank_name' => 'Bank' }
    req['card'] = { 'card_number' => '4111111111111111', 'holder_name' => 'IVAN PETROV' }
    req['sepa'] = { 'iban' => 'DE89370400440532013000', 'holder_name' => 'IVAN PETROV' }
    if recipient.is_a?(Hash) && recipient['type']
      req[recipient['type']] = recipient.reject { |key, _| key == 'type' }
    end
    req
  end

  def operation(request = {}, input = {})
    unless input.empty?
      return Struct.new(:amount, :id, :payout_requisite, :provider_operation_id, :idempotency_key,
                        keyword_init: true).new(
        amount: input['amount'] || 15_000, id: input['id'] || 'op_test',
        payout_requisite: requisite.merge(input['payout_requisite'] || {}),
        provider_operation_id: input['provider_operation_id'] || 'op_prov',
        idempotency_key: input['idempotency_key'] || 'idem_1'
      )
    end

    amount = request['amount'] || 15_000
    amount /= 100.0 if request['amount']
    Struct.new(:amount, :id, :payout_requisite, :provider_operation_id, :idempotency_key,
               keyword_init: true).new(
      amount: amount,
      id: request['external_id'] || request['reference'] || request['order_id'] || 'op_test',
      payout_requisite: requisite(request['recipient']), provider_operation_id: 'op_prov',
      idempotency_key: 'idem_1'
    )
  end

  def service(status, body)
    mock = MockClient.new(status, body)
    instance = Provider::SwiftpayService.new(provider: provider)
    instance.instance_variable_set(:@client, mock)
    [instance, mock]
  end

  def assert_result(result, expected)
    expected['status'] == 'success' ? assert(result.success?) : assert(result.failed?)
    assert_equal expected['operation_status'], result.data[:status] if expected['operation_status']
    if expected['provider_operation_id']
      assert_equal expected['provider_operation_id'], result.data[:provider_operation_id]
    end
    assert_equal expected['internal_code'], result.message if expected['internal_code']
  end

  def assert_request(request, fixtures, method)
    endpoint_method, path = fixtures.fetch('endpoint').split(' ', 2)
    path = path.gsub(/\{[^}]+\}/, 'op_prov')
    assert_equal method, endpoint_method
    assert_equal method, request[:method]
    expected_url = "#{FIXTURES['base_url']}#{path}"
    auth = FIXTURES['auth']
    if auth && auth['location'] == 'query'
      value = provider.credentials[auth['credentials_field']]
      expected_url += "?#{URI.encode_www_form_component(auth['header'])}=#{URI.encode_www_form_component(value)}"
    end
    assert_equal expected_url, request[:url]
    assert_equal fixtures['request'], JSON.parse(JSON.generate(request[:json])) if fixtures['request']
    assert_auth_header request[:headers]
    if fixtures['idempotency_header']
      assert_equal 'idem_1', request[:headers][fixtures['idempotency_header']]
    end
  end

  def assert_auth_header(headers)
    auth = FIXTURES['auth']
    return unless auth && auth['header'] && auth['location'] != 'query'

    expected = case auth['type']
               when 'apiKey' then provider.credentials[auth['credentials_field']]
               when 'http'
                 auth['credentials_field'] == 'username' ?
                   "Basic #{Base64.strict_encode64('u:p')}" : "Bearer #{provider.credentials[auth['credentials_field']]}"
               end
    assert_equal expected, headers[auth['header']] if expected
  end

  def test_check_conditions
    instance, = service(200, {})
    assert instance.check_conditions(operation, 'create').success?
  end

  (FIXTURES['create_request'] || {}).keys.grep(/\Aresponse_\d{3}(?:_.+)?\z/).each do |response_key|
    define_method("test_create_#{response_key}") do
      fixtures = FIXTURES['create_request']
      code = response_key[/\Aresponse_(\d{3})/, 1].to_i
      skip "HTTP #{code} не объявлен успешным в OpenAPI" if code.between?(200, 299) && !CREATE_SUCCESS_CODES.include?(code)
      expected_key = response_key.sub(/\Aresponse_/, 'expected_')
      expected = fixtures[expected_key]
      skip "нет #{expected_key}" unless expected

      instance, mock = service(code, fixtures[response_key])
      result = instance.create_request(operation(fixtures['request'] || {}, fixtures['operation'] || {}))
      assert_result result, expected
      assert_request mock.requests.last, fixtures, 'POST'
    end
  end

  (FIXTURES['fetch_status'] || {}).keys.grep(/\Aresponse_\d{3}(?:_.+)?\z/).each do |response_key|
    define_method("test_status_#{response_key}") do
      fixtures = FIXTURES['fetch_status']
      code = response_key[/\Aresponse_(\d{3})/, 1].to_i
      expected_key = response_key.sub(/\Aresponse_/, 'expected_')
      expected = fixtures[expected_key]
      skip "нет #{expected_key}" unless expected

      instance, mock = service(code, fixtures[response_key])
      result = instance.fetch_status(operation)
      assert_result result, expected
      assert_request mock.requests.last, fixtures, 'GET'
    end
  end

  def sign(raw, callback)
    digest = OpenSSL::HMAC.digest(callback['signature_alg'] || 'SHA256', 'test_secret', raw)
    callback['signature_encoding'] == 'base64' ? Base64.strict_encode64(digest) : digest.unpack1('H*')
  end

  def process_callback(instance, payload, callback, entry, signature = nil)
    if instance.method(:process_callback).arity == 1
      payload['_signature'] = signature || sign(JSON.generate(payload), callback)
      instance.process_callback(payload)
    else
      raw_body = entry['raw_body'] || JSON.pretty_generate(payload)
      instance.process_callback(raw_body, signature || sign(raw_body, callback), {})
    end
  end

  callback = FIXTURES['callback'] || {}
  callback.each do |name, entry|
    next unless entry.is_a?(Hash) && entry['payload']

    define_method("test_callback_#{name}") do
      payload = entry['payload'].dup
      instance = Provider::SwiftpayService.new(provider: provider)
      result = process_callback(instance, payload, callback, entry)
      expected = entry['expected_operation_status']
      skip 'нет ожидаемого статуса callback' unless expected

      if expected == 'rejected'
        assert result.failed?
        assert_equal :rejected, result.code
      else
        assert result.success?
        assert_equal expected, result.data[:status]
      end
    end
  end

  def test_callback_signature_contract
    callback = FIXTURES['callback']
    skip 'в спецификации нет callback' unless callback
    skip 'в спецификации нет подписи callback' unless callback['signature_header']

    entry = callback.values.find { |value| value.is_a?(Hash) && value['payload'] }
    skip 'в спецификации нет callback payload' unless entry

    payload = entry['payload'].dup
    assert_raises(Provider::UnauthorizedError) do
      instance = Provider::SwiftpayService.new(provider: provider)
      process_callback(instance, payload, callback, entry, 'invalid')
    end
  end

  def test_callback_rejects_invalid_json
    skip 'в спецификации нет callback' unless FIXTURES['callback']

    instance = Provider::SwiftpayService.new(provider: provider)
    result = instance.process_callback('{broken-json', nil, {})
    assert result.failed?
    assert_equal :unprocessable_entity, result.code
    assert_equal 'invalid_json', result.message
  end
end
