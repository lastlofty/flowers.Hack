# frozen_string_literal: true

require 'json'
require 'openssl'
require 'base64'

module Paybridge
  # Прогоняет fixtures.json против СГЕНЕРИРОВАННОГО сервиса: подменяет HTTP-клиент
  # мок-клиентом, вызывает методы контракта и сверяет результат с ожиданиями.
  # Доказывает, что интеграция реально работает, а не только компилируется.
  class Verifier
    class LoadError < StandardError; end

    Case = Struct.new(:name, :ok, :detail, keyword_init: true)

    Report = Struct.new(:cases, keyword_init: true) do
      def passed = cases.count(&:ok)
      def failed = cases.reject(&:ok).size
      def all_passed? = failed.zero?
    end

    # Мок HTTP-клиента: возвращает заранее уложенные ответы.
    class MockClient
      def initialize
        @queue = []
      end

      def push(status, body)
        @queue << Provider::HttpClient::Response.new(status: status, body: body)
        self
      end

      def post(_url, json: nil, headers: {})
        @queue.shift
      end

      def get(_url, headers: {})
        @queue.shift
      end
    end

    FakeProvider  = Struct.new(:credentials)
    FakeOperation = Struct.new(
      :amount, :id, :payout_requisite, :provider_operation_id, :idempotency_key,
      keyword_init: true
    )

    def initialize(dir)
      @dir = dir
    end

    def run
      load_service!
      cases = []
      cases.concat(verify_conditions)
      cases.concat(verify_create)
      cases.concat(verify_status)
      cases.concat(verify_callback)
      Report.new(cases: cases)
    end

    private

    def load_service!
      base = File.expand_path(File.join(@dir, 'base_service.rb'))
      raise LoadError, "Нет base_service.rb в #{@dir}" unless File.exist?(base)

      require base unless defined?(Provider::BaseService)

      @fixtures = JSON.parse(File.read(File.join(@dir, 'fixtures.json')))
      provider = @fixtures['provider']

      # Файл сервиса выбираем по имени провайдера — в каталоге может лежать
      # несколько сгенерированных сервисов.
      service_file = File.join(@dir, "#{provider}_service.rb")
      service_file = Dir[File.join(@dir, '*_service.rb')]
                     .reject { |f| File.basename(f) == 'base_service.rb' }.first \
        unless File.exist?(service_file)
      raise LoadError, "Нет сервиса для '#{provider}' в #{@dir}" unless service_file && File.exist?(service_file)

      klass = class_name(provider)
      require File.expand_path(service_file) unless Provider.const_defined?(klass, false)
      @service_class = Provider.const_get(klass)
    end

    def class_name(provider)
      provider.to_s.split(/[_\-\s]+/).map(&:capitalize).join + 'Service'
    end

    # --- сценарии --------------------------------------------------------

    def verify_conditions
      result = call { |svc| svc.check_conditions(operation, 'create') }
      [kase('check_conditions.normal', result.success?, result)]
    end

    def verify_create
      fx = @fixtures['create_request'] or return []
      cases = []

      if fx['response_201'] && fx['expected_201']
        exp = fx['expected_201']
        result = with_client([201, fx['response_201']]) { |svc| svc.create_request(operation) }
        ok = result.success? &&
             eq(result.data && result.data[:status], exp['operation_status']) &&
             eq(result.data && result.data[:provider_operation_id], exp['provider_operation_id'])
        cases << kase('create_request.response_201', ok, result)
      end

      fx.keys.grep(/\Aresponse_(4\d\d|5\d\d)\z/).each do |key|
        code = key[/\d+/].to_i
        result = with_client([code, fx[key]]) { |svc| svc.create_request(operation) }
        expected = fx["expected_#{code}"] || {}
        ok = result.failed?
        ok &&= eq(result.message, expected['internal_code']) if expected['internal_code']
        cases << kase("create_request.#{key}", ok, result)
      end
      cases
    end

    def verify_status
      fx = @fixtures['fetch_status'] or return []
      cases = []
      fx.each do |key, body|
        next unless key.start_with?('response_') && body.is_a?(Hash) && body['status']

        expected = fx["expected_#{key.split('_').last}"]
        next unless expected && expected['operation_status']

        result = with_client([200, body]) { |svc| svc.fetch_status(operation) }
        ok = result.success? && eq(result.data && result.data[:status], expected['operation_status'])
        cases << kase("fetch_status.#{key}", ok, result)
      end
      cases
    end

    def verify_callback
      fx = @fixtures['callback'] or return []
      alg = fx['signature_alg'] || 'SHA256'
      enc = fx['signature_encoding'] || 'hex'
      cases = []

      fx.each do |name, val|
        next unless val.is_a?(Hash) && val['payload']

        payload = val['payload'].dup
        payload['_signature'] = sign(payload, alg, enc)
        result = call { |svc| svc.process_callback(payload) }
        cases << kase("callback.#{name}", callback_ok?(result, val['expected_operation_status']), result)
      end
      cases << verify_invalid_signature(fx) if fx['signature_header']
      cases
    end

    def verify_invalid_signature(fx)
      entry = fx.values.find { |value| value.is_a?(Hash) && value['payload'] }
      return Case.new(name: 'callback.invalid_signature', ok: true, detail: 'нет payload') unless entry

      payload = entry['payload'].merge('_signature' => 'invalid')
      call { |svc| svc.process_callback(payload) }
      Case.new(name: 'callback.invalid_signature', ok: false, detail: 'подпись принята')
    rescue Provider::UnauthorizedError
      Case.new(name: 'callback.invalid_signature', ok: true, detail: 'подпись отклонена')
    end

    def callback_ok?(result, expected)
      case expected
      when 'approved', 'in_progress' then result.success? && eq(result.data && result.data[:status], expected)
      when 'rejected'                then result.failed? && result.code == :rejected
      else result.is_a?(Provider::Result) # unknown-event и т.п. — главное, что не упало
      end
    end

    # --- вспомогательное -------------------------------------------------

    def with_client(*responses)
      call do |svc|
        mock = MockClient.new
        responses.each { |(status, body)| mock.push(status, body) }
        svc.instance_variable_set(:@client, mock)
        yield svc
      end
    end

    def call
      yield @service_class.new(provider: fake_provider)
    end

    def sign(payload, alg, encoding)
      raw = JSON.generate(payload)
      secret = 'test_secret'
      if encoding == 'base64'
        Base64.strict_encode64(OpenSSL::HMAC.digest(alg, secret, raw))
      else
        OpenSSL::HMAC.hexdigest(alg, secret, raw)
      end
    end

    def fake_provider
      FakeProvider.new({
                         'api_key' => 'test_key', 'token' => 'test_token',
                         'callback_secret' => 'test_secret', 'username' => 'u', 'password' => 'p'
                       })
    end

    def operation
      FakeOperation.new(
        amount: 15_000,
        id: 'op_test',
        payout_requisite: fake_requisite,
        provider_operation_id: 'op_prov',
        idempotency_key: 'idem_1'
      )
    end

    # Реквизиты с реалистичными значениями для известных групп и разумной
    # заглушкой для любой другой — новый тип реквизитов не ломает verify.
    def fake_requisite
      req = Hash.new { |h, group| h[group] = Hash.new { |_g, field| "test_#{field}" } }
      req['sbp']  = { 'phone' => '79001234567', 'bank_code' => '044525225', 'bank_name' => 'Bank' }
      req['card'] = { 'card_number' => '4111111111111111', 'holder_name' => 'IVAN PETROV' }
      req['sepa'] = { 'iban' => 'DE89370400440532013000', 'holder_name' => 'IVAN PETROV' }
      req
    end

    def eq(actual, expected)
      actual.to_s == expected.to_s
    end

    def kase(name, ok, result)
      Case.new(name: name, ok: ok, detail: detail(result))
    end

    def detail(result)
      if result.success?
        "success #{result.data.inspect}"
      else
        "failed #{result.code} #{result.message}"
      end
    end
  end
end
