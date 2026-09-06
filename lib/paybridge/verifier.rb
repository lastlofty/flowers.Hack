# frozen_string_literal: true

require 'base64'
require 'json'
require 'openssl'
require 'time'
require 'uri'

module Paybridge
  # Выполняется только внутри одноразовой ограниченной среды, которую создаёт
  # VerificationRunner. Сам Verifier не является границей безопасности.
  class Verifier
    class LoadError < StandardError; end

    Case = Struct.new(:name, :status, :ok, :detail, keyword_init: true) do
      def to_h
        { name: name, status: status, ok: ok, detail: detail }
      end

      def self.from_h(value)
        new(name: value.fetch('name'), status: value.fetch('status'),
            ok: value['ok'], detail: value.fetch('detail', ''))
      end
    end

    Report = Struct.new(:cases, :checked_at, :execution_error, keyword_init: true) do
      def passed = cases.count { |item| item.status == 'passed' }
      def failed = cases.count { |item| item.status == 'failed' }
      def skipped = cases.count { |item| item.status == 'skipped' }

      def status
        return 'error' if execution_error
        return 'failed' if failed.positive?
        return 'partial' if skipped.positive? || passed.zero?

        'passed'
      end

      def all_passed? = status == 'passed'

      def to_h
        { status: status, passed: passed, failed: failed, skipped: skipped,
          checked_at: checked_at, cases: cases.map(&:to_h) }
      end

      def self.from_h(value)
        new(cases: Array(value['cases']).map { |item| Case.from_h(item) },
            checked_at: value['checked_at'], execution_error: value['status'] == 'error')
      end
    end

    # Записывает фактический запрос и возвращает подготовленный ответ.
    class MockClient
      attr_reader :requests

      def initialize
        @queue = []
        @requests = []
      end

      def push(status, body)
        @queue << Provider::HttpClient::Response.new(status: status, body: body)
        self
      end

      def post(url, json: nil, headers: {}) = record('POST', url, headers, json)
      def get(url, headers: {}) = record('GET', url, headers, nil)

      private

      def record(method, url, headers, json)
        @requests << { method: method, url: url, headers: headers, json: json }
        @queue.shift || raise('MockClient: ответ не подготовлен')
      end
    end

    FakeProvider = Struct.new(:credentials)
    FakeOperation = Struct.new(:amount, :currency, :id, :payout_requisite, :provider_operation_id,
                               :idempotency_key, keyword_init: true)

    def initialize(dir)
      @dir = File.expand_path(dir)
    end

    def run
      load_service!
      cases = [guarded('check_conditions.normal') { verify_conditions }]
      cases.concat(verify_create)
      cases.concat(verify_status)
      cases.concat(verify_callback)
      Report.new(cases: cases, checked_at: Time.now.utc.iso8601)
    end

    private

    def load_service!
      base = File.join(@dir, 'base_service.rb')
      fixtures_path = File.join(@dir, 'fixtures.json')
      raise LoadError, 'Нет base_service.rb' unless File.file?(base)
      raise LoadError, 'Нет fixtures.json' unless File.file?(fixtures_path)

      @fixtures = JSON.parse(File.read(fixtures_path, 1_000_001))
      provider = @fixtures['provider'].to_s
      raise LoadError, 'Некорректный provider в fixtures.json' unless provider.match?(Paybridge::PROVIDER_RE)

      service_file = File.join(@dir, "#{provider}_service.rb")
      raise LoadError, "Нет сервиса для '#{provider}'" unless File.file?(service_file)

      @service_source = File.read(service_file, 1_000_001)

      # Worker всегда новый, поэтому загружается именно текущая интеграция.
      # base_service.rb — фиксированный платформенный стаб; при повторной загрузке
      # (несколько интеграций в одном процессе, напр. в тестах) его константы
      # переопределяются, давая шумные "already initialized constant". Глушим
      # только этот load; сгенерированный сервис грузим с полными предупреждениями.
      silence_warnings { load base }
      load service_file
      @service_class = Provider.const_get(class_name(provider), false)
    rescue JSON::ParserError => e
      raise LoadError, "Некорректный fixtures.json: #{e.message}"
    rescue NameError => e
      raise LoadError, "Сервис не определил ожидаемый класс: #{e.message}"
    end

    def class_name(provider)
      "#{provider.split(/[_\-\s]+/).map(&:capitalize).join}Service"
    end

    def silence_warnings
      old = $VERBOSE
      $VERBOSE = nil
      yield
    ensure
      $VERBOSE = old
    end

    def verify_conditions
      result = call { |service| service.check_conditions(operation, 'create') }
      [result.success?, result_detail(result)]
    end

    def verify_create
      fixtures = @fixtures['create_request']
      return [skipped('create_request', 'В fixtures нет сценариев создания')] unless fixtures.is_a?(Hash)

      response_keys(fixtures).reject { |key| synthetic_success_code?(key) }.map do |key|
        code = response_code(key)
        guarded("create_request.#{key}") do
          expected_key = key.sub(/\Aresponse_/, 'expected_')
          expected = fixtures[expected_key]
          next [nil, "Для HTTP #{code} нет независимого #{expected_key}"] unless expected.is_a?(Hash)

          result, request = with_client([code, fixtures[key]]) do |service|
            service.create_request(operation_for(fixtures))
          end
          assertions = [verify_result(result, expected), verify_request(request, fixtures, 'POST')]
          source_key = "source_#{key.delete_prefix('response_')}"
          detail = assertions.map(&:last).push("source=#{fixtures[source_key] || 'legacy'}")
          [assertions.all?(&:first), detail.join('; ')]
        end
      end
    end

    def verify_status
      fixtures = @fixtures['fetch_status']
      return [skipped('fetch_status', 'В fixtures нет сценариев статуса')] unless fixtures.is_a?(Hash)

      response_keys(fixtures).map do |key|
        code = response_code(key)
        guarded("fetch_status.#{key}") do
          expected_key = key.sub(/\Aresponse_/, 'expected_')
          expected = fixtures[expected_key]
          next [nil, "Для HTTP #{code} нет независимого #{expected_key}"] unless expected.is_a?(Hash)

          result, request = with_client([code, fixtures[key]]) { |service| service.fetch_status(operation) }
          assertions = [verify_result(result, expected), verify_request(request, fixtures, 'GET')]
          [assertions.all?(&:first), assertions.map(&:last).join('; ')]
        end
      end
    end

    def verify_callback
      fixtures = @fixtures['callback']
      return [skipped('callback.signature', 'В спецификации нет callback-примеров')] unless fixtures.is_a?(Hash)

      entries = fixtures.filter_map do |name, value|
        next unless value.is_a?(Hash) && value['payload'].is_a?(Hash)

        guarded("callback.#{name}") { verify_callback_entry(value, fixtures) }
      end
      entries << if fixtures['signature_header']
                   guarded('callback.invalid_signature') { verify_invalid_signature(fixtures) }
                 else
                   skipped('callback.signature', 'Спецификация не описывает подпись callback')
                 end
      entries << skipped('callback.examples', 'В спецификации нет callback payload') if entries.empty?
      entries
    end

    def verify_callback_entry(entry, fixtures)
      payload = entry['payload'].dup
      result = call { |service| process_callback(service, payload, fixtures, entry: entry) }
      expected = entry['expected_operation_status']
      ok = case expected
           when 'approved', 'in_progress'
             result.success? && same_value?(result.data && result.data[:status], expected)
           when 'rejected'
             result.failed? && result.code == :rejected
           else false
           end
      [ok, expected ? result_detail(result) : 'Нет ожидаемого статуса callback']
    end

    def verify_invalid_signature(fixtures)
      entry = fixtures.values.find { |value| value.is_a?(Hash) && value['payload'].is_a?(Hash) }
      return [nil, 'В спецификации нет callback payload'] unless entry

      call { |service| process_callback(service, entry['payload'].dup, fixtures, entry: entry, signature: 'invalid') }
      [false, 'Неверная подпись была принята']
    rescue Provider::UnauthorizedError
      [true, 'Неверная подпись отклонена']
    end

    def response_keys(fixtures)
      fixtures.keys.grep(/\Aresponse_\d{3}(?:_.+)?\z/).sort_by { |key| [response_code(key), key] }
    end

    def response_code(key) = key[/\Aresponse_(\d{3})/, 1].to_i

    def synthetic_success_code?(key)
      code = response_code(key)
      code.between?(200, 299) && !declared_create_success_codes.include?(code)
    end

    def declared_create_success_codes
      @declared_create_success_codes ||= begin
        declared = @fixtures.dig('create_request', 'success_codes')
        if declared.is_a?(Array) && !declared.empty?
          # Контракт v3: коды успеха объявлены явно в fixtures.json.
          declared.map(&:to_i)
        else
          # Совместимость с v2: реверсим из текста сервиса (case response.status).
          match = @service_source.match(/case response\.status\s+when\s+([\d,\s]+)/m)
          match ? match[1].scan(/\d{3}/).map(&:to_i) : []
        end
      end
    end

    def verify_result(result, expected)
      ok = expected['status'] == 'success' ? result.success? : result.failed?
      if expected['operation_status']
        ok &&= same_value?(result.data && result.data[:status], expected['operation_status'])
      end
      if expected['provider_operation_id']
        ok &&= same_value?(result.data && result.data[:provider_operation_id], expected['provider_operation_id'])
      end
      ok &&= same_value?(result.message, expected['internal_code']) if expected['internal_code']
      [ok, result_detail(result)]
    end

    def verify_request(request, fixtures, method)
      return [false, 'Исходящий HTTP-запрос не выполнен'] unless request

      endpoint_method, endpoint_path = fixtures['endpoint'].to_s.split(' ', 2)
      checks = [same_value?(request[:method], method), same_value?(request[:url], expected_url(endpoint_path))]
      details = ["#{request[:method]} #{request[:url]}"]
      expected_headers(fixtures).each do |name, value|
        checks << same_value?(request[:headers][name], value)
        details << "header #{name}"
      end
      if method == 'POST' && fixtures['request'].is_a?(Hash)
        checks << same_value?(normalize_json(request[:json]), normalize_json(fixtures['request']))
        details << 'JSON body'
      end
      checks << same_value?(endpoint_method, method)
      [checks.all?, details.join(', ')]
    end

    def expected_url(path)
      value = path.to_s.gsub(/\{[^}]+\}/, operation.provider_operation_id.to_s)
      url = "#{@fixtures['base_url']}#{value}"
      auth = @fixtures['auth']
      return url unless auth.is_a?(Hash) && auth['location'] == 'query'

      separator = url.include?('?') ? '&' : '?'
      credential = fake_provider.credentials[auth['credentials_field']]
      "#{url}#{separator}#{URI.encode_www_form_component(auth['header'])}=#{URI.encode_www_form_component(credential)}"
    end

    def expected_headers(fixtures)
      auth = @fixtures['auth']
      headers = {}
      if auth.is_a?(Hash) && auth['header'] && auth['location'] != 'query'
        value = case auth['type']
                when 'apiKey' then fake_provider.credentials[auth['credentials_field']]
                when 'http'
                  if http_basic?(auth)
                    "Basic #{Base64.strict_encode64('u:p')}"
                  else
                    "Bearer #{fake_provider.credentials[auth['credentials_field']]}"
                  end
                end
        headers[auth['header']] = value if value
      end
      headers[fixtures['idempotency_header']] = 'idem_1' if fixtures['idempotency_header']
      headers
    end

    # Basic vs Bearer: контракт v3 несёт auth.scheme явно; для старых фикстур
    # (без scheme) — совместимость по credentials_field (парсер ставит 'password'
    # для basic, 'token' для bearer).
    def http_basic?(auth)
      return auth['scheme'] == 'basic' if auth.key?('scheme')

      auth['credentials_field'] == 'password' || auth['credentials_field'] == 'username'
    end

    def operation_for(fixtures)
      input = fixtures['operation']
      if input.is_a?(Hash)
        return FakeOperation.new(
          amount: input['amount'] || operation.amount,
          currency: input['currency'] || operation.currency,
          id: input['id'] || operation.id,
          payout_requisite: fake_requisite.merge(input['payout_requisite'] || {}),
          provider_operation_id: input['provider_operation_id'] || operation.provider_operation_id,
          idempotency_key: input['idempotency_key'] || operation.idempotency_key
        )
      end

      request = fixtures['request'] || {}
      amount = request['amount'] || operation.amount
      amount /= 100.0 if minor_units_documented?
      FakeOperation.new(
        amount: amount,
        currency: request['currency'] || operation.currency,
        id: request['external_id'] || request['reference'] || request['order_id'] || operation.id,
        payout_requisite: requisite_from(request['recipient']),
        provider_operation_id: operation.provider_operation_id,
        idempotency_key: operation.idempotency_key
      )
    end

    def minor_units_documented?
      guide = File.join(@dir, 'INTEGRATION.md')
      File.file?(guide) && File.read(guide, 100_001).include?('operation.amount * 100')
    rescue ArgumentError
      false
    end

    def requisite_from(recipient)
      return fake_requisite unless recipient.is_a?(Hash)

      type = recipient['type'].to_s
      return fake_requisite if type.empty?

      fake_requisite.merge(type => recipient.except('type'))
    end

    def with_client(*responses)
      mock = MockClient.new
      responses.each { |(status, body)| mock.push(status, body) }
      result = call do |service|
        service.instance_variable_set(:@client, mock)
        yield service
      end
      [result, mock.requests.last]
    end

    def call
      yield @service_class.new(provider: fake_provider)
    end

    def guarded(name)
      ok, detail = yield
      return skipped(name, detail) if ok.nil?

      Case.new(name: name, status: ok ? 'passed' : 'failed', ok: ok, detail: safe_detail(detail))
    rescue StandardError => e
      Case.new(name: name, status: 'failed', ok: false,
               detail: safe_detail("#{e.class}: #{e.message}"))
    end

    def skipped(name, detail)
      Case.new(name: name, status: 'skipped', ok: nil, detail: detail)
    end

    def process_callback(service, payload, fixtures, entry:, signature: nil)
      if service.method(:process_callback).arity == 1
        payload['_signature'] = signature || sign(JSON.generate(payload), fixtures)
        service.process_callback(payload)
      else
        raw_body = entry['raw_body'] || JSON.pretty_generate(payload)
        service.process_callback(raw_body, signature || sign(raw_body, fixtures), {})
      end
    end

    def sign(raw, fixtures)
      digest = OpenSSL::HMAC.digest(fixtures['signature_alg'] || 'SHA256', 'test_secret', raw)
      fixtures['signature_encoding'] == 'base64' ? Base64.strict_encode64(digest) : digest.unpack1('H*')
    end

    def fake_provider
      FakeProvider.new({ 'api_key' => 'test_key', 'token' => 'test_token', 'callback_secret' => 'test_secret',
                         'username' => 'u', 'password' => 'p' })
    end

    def operation
      @operation ||= FakeOperation.new(amount: 15_000, currency: 'RUB', id: 'op_test',
                                       payout_requisite: fake_requisite,
                                       provider_operation_id: 'op_prov', idempotency_key: 'idem_1')
    end

    def fake_requisite
      req = Hash.new { |hash, group| hash[group] = Hash.new { |_nested, field| "test_#{field}" } }
      req['sbp'] = { 'phone' => '79001234567', 'bank_code' => '044525225', 'bank_name' => 'Bank' }
      req['card'] = { 'card_number' => '4111111111111111', 'holder_name' => 'IVAN PETROV' }
      req['sepa'] = { 'iban' => 'DE89370400440532013000', 'holder_name' => 'IVAN PETROV' }
      req
    end

    def same_value?(actual, expected) = actual == expected
    def normalize_json(value) = JSON.parse(JSON.generate(value))

    def result_detail(result)
      return 'Результат success соответствует сценарию' if result.success?

      "Результат failed: #{result.code} #{result.message}"
    end

    def safe_detail(value)
      value.to_s.encode('UTF-8', invalid: :replace, undef: :replace).slice(0, 500)
    end
  end
end
