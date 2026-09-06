# frozen_string_literal: true

require 'minitest/autorun'
require 'tempfile'
require 'tmpdir'
require 'fileutils'
require 'rbconfig'
require_relative '../lib/paybridge'
require_relative '../lib/paybridge/templates/base_service'

# P1: коды успеха из спеки, авторизация по security, webhook без подписи,
# неполный ответ. Регрессии на конкретные сценарии из ТЗ.
class TestHttpAuth < Minitest::Test
  # Минимальная спека с настраиваемыми: кодом успеха, схемами, security, webhook.
  def indent(str, spaces)
    str.gsub(/^(?=.)/, ' ' * spaces)
  end

  def spec_yaml(success_code: '201', schemes: 'Key: { type: apiKey, in: header, name: X-Api-Key }',
                op_security: '[ { Key: [] } ]', webhook: false)
    hook = webhook ? indent(<<~HOOK, 2) : ''
      /hooks/x:
        post:
          operationId: hook
          security: []
          requestBody:
            required: true
            content: { application/json: { schema: { type: object, required: [event, id, status], properties: { event: {type: string, enum: [x.done, x.failed]}, id: {type: string}, status: {type: string, enum: [pending, completed, failed]} } } } }
          responses: { '200': { description: ok } }
    HOOK
    <<~YAML
      openapi: 3.0.3
      info: { title: T, version: "1.0.0" }
      servers: [ { url: https://x.example/v1 } ]
      paths:
        /pay:
          post:
            operationId: create
            security: #{op_security}
            requestBody:
              required: true
              content:
                application/json:
                  schema:
                    type: object
                    required: [amount]
                    properties:
                      amount: { type: integer, minimum: 100 }
            responses:
              '#{success_code}':
                description: ok
                content:
                  application/json:
                    schema:
                      type: object
                      properties:
                        id: { type: string }
                        status: { type: string, enum: [pending, completed] }
        /pay/{id}:
          get:
            operationId: get
            security: #{op_security}
            parameters: [ { name: id, in: path, required: true, schema: { type: string } } ]
            responses:
              '200': { description: ok, content: { application/json: { schema: { type: object, properties: { id: {type: string}, status: {type: string, enum: [pending, completed]} } } } } }
      #{hook}
      components:
        securitySchemes:
          #{schemes}
    YAML
  end

  def generate(**opts)
    f = Tempfile.new(['s', '.yaml'])
    f.write(spec_yaml(**opts))
    f.rewind
    Paybridge.generate(spec_path: f.path, provider: 'testpay')
  ensure
    f.close!
  end

  def load_service(gen)
    dir = Dir.mktmpdir('pb_ha_')
    File.write(File.join(dir, 'testpay_service.rb'), gen.files['testpay_service.rb'])
    FileUtils.cp(Paybridge::BASE_SERVICE, File.join(dir, 'base_service.rb'))
    require File.join(dir, 'base_service.rb') unless defined?(Provider::BaseService)
    require File.join(dir, 'testpay_service.rb') unless Provider.const_defined?(:TestpayService, false)
    Provider::TestpayService
  end

  def provider
    Struct.new(:credentials).new({ 'api_key' => 'k', 'token' => 'k' })
  end

  def operation
    Struct.new(:amount, :id, :payout_requisite, :provider_operation_id, :idempotency_key,
               keyword_init: true).new(amount: 5, id: 'op', payout_requisite: {},
                                       provider_operation_id: 'pop', idempotency_key: 'i')
  end

  def mock_client(status, body)
    Class.new do
      define_method(:initialize) { @r = Provider::HttpClient::Response.new(status: status, body: body) }
      define_method(:post) { |*_a, **_k| @r }
      define_method(:get)  { |*_a, **_k| @r }
    end.new
  end

  # §5: 200 как код успеха создания
  def test_success_code_200_from_spec
    code = generate(success_code: '200').files['testpay_service.rb']
    assert_includes code, 'when 200'
    refute_includes code, 'when 201'
  end

  # §5: неполный ответ (нет id) — определённый отказ, а не success со nil
  def test_incomplete_response_is_failure
    klass = load_service(generate(success_code: '201'))
    svc = klass.new(provider: provider)
    svc.instance_variable_set(:@client, mock_client(201, { 'status' => 'pending' })) # нет id
    result = svc.create_request(operation)
    assert result.failed?
    assert_equal :unprocessable_entity, result.code
  end

  # §6: спецификация без авторизации — auth_headers пустые, без NameError
  def test_no_auth_generates_empty_headers
    code = generate(op_security: '[]', schemes: '{}').files['testpay_service.rb']
    assert_includes code, 'def auth_headers'
    assert_match(/def auth_headers\s*\n\s*\{\}/, code)
    assert syntax_ok?(code), code
  end

  # §6: webhook без подписи — нет вызова verify_signature!, без NoMethodError
  def test_webhook_without_signature_has_no_verify_call
    code = generate(webhook: true).files['testpay_service.rb']
    assert_includes code, 'def process_callback'
    refute_includes code, 'verify_signature!'
    assert syntax_ok?(code), code
  end

  def test_network_error_becomes_controlled_failure
    klass = load_service(generate(success_code: '201'))
    failing_client = Object.new
    failing_client.define_singleton_method(:post) { |*_args, **_kwargs| raise Provider::NetworkError, 'timeout' }
    service = klass.new(provider: provider)
    service.instance_variable_set(:@client, failing_client)

    result = service.create_request(operation)
    assert result.failed?
    assert_equal :service_unavailable, result.code
    assert_equal 'provider.network_error', result.message
  end

  def test_non_object_status_response_is_controlled_failure
    klass = load_service(generate(success_code: '201'))
    service = klass.new(provider: provider)
    service.instance_variable_set(:@client, mock_client(200, ['unexpected']))

    result = service.fetch_status(operation)
    assert result.failed?
    assert_equal :unprocessable_entity, result.code
    assert_equal 'unknown_status', result.message
  end

  def test_http_client_applies_configured_timeouts
    response = Struct.new(:code, :body).new('200', '{}')
    http = Object.new
    class << http
      attr_accessor :use_ssl, :open_timeout, :read_timeout, :write_timeout
    end
    http.define_singleton_method(:request) { |_request| response }

    Net::HTTP.stub(:new, http) do
      result = Provider::HttpClient.new(open_timeout: 1, read_timeout: 2, write_timeout: 3)
                                   .get('https://provider.example/status')
      assert_equal 200, result.status
    end
    assert_equal true, http.use_ssl
    assert_equal 1.0, http.open_timeout
    assert_equal 2.0, http.read_timeout
    assert_equal 3.0, http.write_timeout
  end

  def test_http_client_rejects_invalid_timeout
    assert_raises(ArgumentError) { Provider::HttpClient.new(read_timeout: 0) }
  end

  def syntax_ok?(code)
    f = Tempfile.new(['svc', '.rb'])
    f.write(code)
    f.rewind
    out = `"#{RbConfig.ruby}" -c "#{f.path}" 2>&1`
    f.close!
    out.include?('Syntax OK')
  end
end
