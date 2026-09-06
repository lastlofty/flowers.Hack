# frozen_string_literal: true

require 'yaml'
require 'date'
require 'digest'
require 'ipaddr'
require 'net/http'
require 'openssl'
require 'socket'
require 'uri'
require_relative 'ir'
require_relative 'report'
require_relative 'safe'
require_relative 'line_index'
require_relative 'mappers/status_mapper'
require_relative 'mappers/error_mapper'
require_relative 'mappers/request_mapper'

module Paybridge
  # Разбирает OpenAPI 3.x спецификацию в модель Paybridge::IR::Spec.
  # Логика универсальна: не привязана к конкретному провайдеру, все
  # провайдер-зависимые решения выводятся из содержимого спеки и config/mapping.yml.
  class SpecParser
    class ParseError < StandardError; end

    def initialize(spec_path, provider_name, config, overrides = {})
      @spec_path = spec_path
      @provider  = provider_name
      @config    = config
      @overrides = overrides || {}
      @report    = Report.new
    end

    VALID_AMOUNT_UNIT  = %w[minor major].freeze
    VALID_SIG_ENCODING = %w[hex base64].freeze
    MAX_SPEC_BYTES = 1_000_000
    URL_OPEN_TIMEOUT = 3
    URL_READ_TIMEOUT = 3
    MAX_REDIRECTS = 3

    # Единая безопасная загрузка источника для генератора, validate и lint.
    # Отдельный экземпляр нужен только для хранения пути; разбор YAML не запускается.
    def self.read_source(spec_path)
      new(spec_path, 'source', {}).send(:read_spec_source)
    end

    def parse
      Safe.provider!(@provider)
      validate_overrides!
      @doc = load_yaml
      validate_openapi!
      guarded_build
    end

    # Остаточные type-ошибки разбора недоверенной спеки -> ParseError (это валидация
    # ввода: тело работает только с @doc из спеки, а не с нашим кодогеном).
    def guarded_build
      build_ir
    rescue ParseError
      raise
    rescue StandardError => e
      raise ParseError, "структура спецификации некорректна (#{e.class}): #{e.message}"
    end

    def build_ir
      endpoints = build_endpoints
      create_candidates = endpoints.select { |e| e.role == :create }
      status_candidates = endpoints.select { |e| e.role == :status }
      warn_ambiguous_endpoints('создания операции', create_candidates)
      warn_ambiguous_endpoints('статус-запроса', status_candidates)

      create    = pick_create(create_candidates)
      status    = pick_status(status_candidates, create)
      cancel    = endpoints.find { |e| e.role == :cancel }
      webhook_e = endpoints.find { |e| e.role == :webhook }

      @report.warn('Не найден метод создания операции (POST) — сервис будет неполным', level: :error) if create.nil?
      @report.warn('Не найден метод статус-запроса (GET {id})') if status.nil?

      status_enum = extract_status_enum(create, status)
      http_codes  = collect_http_codes(endpoints)

      status_map = Mappers::StatusMapper.new(@config, @report).build(status_enum)
      error_mapper = Mappers::ErrorMapper.new(@config, @report)
      error_map, http_symbol = error_mapper.build(http_codes)

      req_schema = create && resolve_deep(create.request_schema)
      req = Mappers::RequestMapper.new(@report, @overrides, field_line: field_line_resolver(create)).build(req_schema)

      IR::Spec.new(
        provider_name: @provider,
        provider_class: Safe.class_name(@provider),
        title: dig(@doc, 'info', 'title'),
        version: dig(@doc, 'info', 'version'),
        base_url: base_url,
        base_url_env: "#{@provider.upcase}_BASE_URL",
        auth: build_auth(create),
        idempotency_header: idempotency_header(endpoints),
        endpoints: endpoints,
        create_endpoint: create,
        status_endpoint: status,
        cancel_endpoint: cancel,
        create_success_codes: create_success_codes(create),
        webhook: build_webhook(webhook_e, status_map),
        status_map: status_map,
        error_map: error_map,
        http_symbol: http_symbol,
        amount: req.amount,
        currency: req.currency,
        external_id_field: req.external_id_field,
        required_requisite: req.required_requisite,
        recipient_spec: req.recipient_spec,
        request_payload_ruby: req.ruby,
        request_examples: request_examples(create),
        response_examples: response_examples(create, status),
        webhook_examples: webhook_examples(webhook_e),
        spec_sha256: @spec_sha256,
        report: @report
      )
    end

    private

    # Резолвер строки поля тела запроса (source-map): callable(field) -> строка
    # спеки или nil. Обрабатывает inline-схему и одиночный $ref на компонент.
    def field_line_resolver(create)
      return nil unless create && @line_index

      op = @doc.dig('paths', create.path, create.http_method) || {}
      content = op.dig('requestBody', 'content')
      return nil unless content.is_a?(Hash)

      content_type = content.keys.first
      schema = content.dig(content_type, 'schema')
      base = ['paths', create.path, create.http_method, 'requestBody', 'content', content_type, 'schema']
      if schema.is_a?(Hash) && schema['$ref'].is_a?(String)
        target = ref_segments(schema['$ref'])
        base = target if target
      end
      ->(field) { @line_index.line_for(*base, 'properties', field) }
    end

    # '#/components/schemas/X' -> ['components','schemas','X']; иначе nil.
    def ref_segments(ref)
      return nil unless ref.start_with?('#/')

      ref.delete_prefix('#/').split('/').map { |seg| seg.gsub('~1', '/').gsub('~0', '~') }
    end

    # Реальные спеки часто содержат example с датой/временем без кавычек
    # (напр. Klarna: 2038-01-19T03:14:07Z). Date/Time — безопасные value-классы,
    # разрешаем их. Опасные классы (!ruby/object и т.п.) по-прежнему запрещены.
    YAML_PERMITTED = [Date, Time].freeze

    def load_yaml
      content = self.class.read_source(@spec_path)
      @spec_sha256 = Digest::SHA256.hexdigest(content)
      @line_index = LineIndex.new(content)
      YAML.safe_load(content, permitted_classes: YAML_PERMITTED, aliases: true)
    rescue Psych::Exception, EncodingError, ArgumentError => e
      # Psych: SyntaxError/DisallowedClass (!ruby/object, символ)/BadAlias;
      # Encoding/Argument: невалидные байты (не-UTF-8 вход от байтового фаззера).
      raise ParseError, "Некорректный YAML: #{e.message}"
    end

    # Источник спецификации: локальный файл или http(s) URL.
    def read_spec_source
      return fetch_url(@spec_path) if @spec_path.to_s.match?(%r{\Ahttps?://}i)

      raise ParseError, "Файл спецификации не найден: #{@spec_path}" unless File.exist?(@spec_path)

      File.read(@spec_path)
    end

    def fetch_url(url, redirects = 0)
      raise ParseError, 'Слишком много перенаправлений при загрузке спецификации' if redirects > MAX_REDIRECTS

      uri = URI.parse(url)
      validate_remote_uri!(uri)
      address = resolve_public_address!(uri.host)
      http = Net::HTTP.new(uri.host, uri.port, nil)
      http.ipaddr = address
      http.use_ssl = uri.scheme == 'https'
      http.open_timeout = URL_OPEN_TIMEOUT
      http.read_timeout = URL_READ_TIMEOUT
      http.write_timeout = URL_OPEN_TIMEOUT

      http.start do |client|
        request = Net::HTTP::Get.new(uri.request_uri, 'Accept' => 'application/yaml, text/yaml, */*')
        client.request(request) do |response|
          if response.is_a?(Net::HTTPRedirection)
            location = response['location']
            raise ParseError, 'Перенаправление URL без Location' if location.to_s.empty?

            return fetch_url(URI.join(uri, location).to_s, redirects + 1)
          end
          unless response.is_a?(Net::HTTPSuccess)
            raise ParseError, "URL спецификации вернул HTTP #{response.code}"
          end

          declared_size = response['content-length'].to_i
          raise ParseError, 'Спецификация по URL больше 1 МБ' if declared_size > MAX_SPEC_BYTES

          content = +''
          response.read_body do |chunk|
            content << chunk
            raise ParseError, 'Спецификация по URL больше 1 МБ' if content.bytesize > MAX_SPEC_BYTES
          end
          return content
        end
      end
    rescue URI::InvalidURIError, SocketError, SystemCallError, Timeout::Error, IOError,
           Net::ProtocolError, OpenSSL::SSL::SSLError => e
      raise ParseError, "Не удалось загрузить спецификацию по URL: #{e.message}"
    end

    def validate_remote_uri!(uri)
      return if %w[http https].include?(uri.scheme) && uri.host && uri.userinfo.nil?

      raise ParseError, 'Разрешены только HTTP(S) URL без credentials'
    end

    def resolve_public_address!(host)
      addresses = Addrinfo.getaddrinfo(host, nil, nil, :STREAM).map(&:ip_address).uniq
      raise ParseError, 'URL не разрешается в IP-адрес' if addresses.empty?
      return addresses.first if ENV['PAYBRIDGE_ALLOW_PRIVATE_SPEC_URLS'] == '1'

      blocked = addresses.any? { |address| blocked_address?(address) }
      raise ParseError, 'URL указывает на локальный или служебный адрес' if blocked

      addresses.first
    end

    def blocked_address?(address)
      ip = IPAddr.new(address)
      multicast = if ip.ipv4?
                    IPAddr.new('224.0.0.0/4').include?(ip)
                  else
                    IPAddr.new('ff00::/8').include?(ip)
                  end
      ip.private? || ip.loopback? || ip.link_local? || multicast || ip.to_i.zero?
    rescue IPAddr::InvalidAddressError
      true
    end

    def validate_openapi!
      unless @doc.is_a?(Hash)
        raise ParseError, 'Это не похоже на OpenAPI-спецификацию'
      end

      version = @doc['openapi'].to_s
      return if version.start_with?('3.')

      if @doc['swagger']
        raise ParseError, 'Swagger 2.0 пока не поддерживается; требуется OpenAPI 3.x'
      end

      raise ParseError, 'Это не похоже на OpenAPI-спецификацию (нет ключа openapi)'
    end

    # Опечатка в overrides не должна молча менять расчёт — отклоняем явно.
    def validate_overrides!
      unit = @overrides['amount_unit']
      if unit && !VALID_AMOUNT_UNIT.include?(unit.to_s)
        raise ParseError, "overrides.amount_unit: недопустимо #{unit.inspect} (ожидается minor|major)"
      end

      enc = @overrides['signature_encoding']
      return unless enc && !VALID_SIG_ENCODING.include?(enc.to_s)

      raise ParseError, "overrides.signature_encoding: недопустимо #{enc.inspect} (ожидается hex|base64)"
    end

    # --- endpoints -------------------------------------------------------

    SAFE_PATH = %r{\A[A-Za-z0-9_\-./{}~%:]+\z}

    def build_endpoints
      unless @doc['paths'].nil? || @doc['paths'].is_a?(Hash)
        raise ParseError, 'Раздел paths должен быть объектом'
      end

      paths = @doc['paths'] || {}
      endpoints = []
      paths.each do |path, methods|
        next unless methods.is_a?(Hash)

        unless path.to_s.match?(SAFE_PATH)
          raise ParseError, "Недопустимый путь в спецификации: #{path.inspect}"
        end

        methods.each do |http_method, op|
          next unless %w[get post put patch delete].include?(http_method)
          next unless op.is_a?(Hash)

          endpoints << IR::Endpoint.new(
            http_method: http_method,
            path: path,
            operation_id: op['operationId'],
            summary: op['summary'],
            role: classify(path, http_method, op),
            path_params: params_in(op, 'path'),
            query_params: params_in(op, 'query'),
            header_params: params_in(op, 'header'),
            request_schema: request_schema(op),
            response_codes: (op['responses'] || {}).keys,
            spec_line: @line_index&.line_for('paths', path, http_method)
          )
        end
      end
      endpoints
    end

    def classify(path, http_method, _op)
      return :webhook if path.match?(/webhook|callback|hook|notif/i)
      return :cancel  if http_method == 'post' && path.match?(/cancel/i)
      return :status  if http_method == 'get' && path.match?(/\{[^}]+\}/)
      return :create  if http_method == 'post' && !path.match?(/\{[^}]+\}/)

      :other
    end

    # На больших спеках POST-методов много (Adyen, Stripe): «первый попавшийся»
    # берёт не тот (напр. /applePay/sessions). Ранжируем кандидатов по «похожести
    # на создание платежа/выплаты»; при равенстве — порядок из спеки (stable).
    PAY_HINT = /pay(ment|out)?s?\b|charg|transfer|deposit|withdraw|invoice|\bsale/i
    NON_PAY_HINT = /session|method|token|detail|3ds|apple|google|\blink|report|
                    balance|refund|capture|dispute|config|setting|test|schedule/xi

    def pick_create(candidates)
      forced_endpoint(candidates, 'create_endpoint') || pick_ranked(candidates)
    end

    # Статус-метод: overrides -> GET {id} на ресурсе создания (общий префикс пути —
    # напр. /payments + /payments/{id}) -> ранжирование по платёжности.
    def pick_status(candidates, create)
      forced = forced_endpoint(candidates, 'status_endpoint')
      return forced if forced

      if create
        stem = create.path[%r{\A/[^/\{]+}o] # первый сегмент пути создания
        same = stem && candidates.find { |e| e.path.start_with?("#{stem}/") }
        return same if same
      end
      pick_ranked(candidates)
    end

    # Ручной выбор эндпоинта через overrides (для больших/неоднозначных спек,
    # где эвристика берёт не тот метод). Значение: "/path" или "POST /path".
    def forced_endpoint(candidates, key)
      value = @overrides[key]
      return nil if value.nil? || value.to_s.strip.empty?

      path = value.to_s.split(/\s+/).last
      match = candidates.find { |endpoint| endpoint.path == path }
      unless match
        @report.warn("overrides.#{key}: путь '#{path}' не найден среди подходящих " \
                     'методов — использую автоматический выбор.')
      end
      match
    end

    def pick_ranked(candidates)
      return candidates.first if candidates.size <= 1

      candidates.each_with_index.max_by do |endpoint, index|
        [endpoint_pay_score(endpoint), -index] # выше счёт, затем ранний порядок
      end&.first
    end

    def endpoint_pay_score(endpoint)
      text = "#{endpoint.path} #{endpoint.operation_id}"
      score = 0
      score += 3 if text.match?(PAY_HINT)
      score -= 3 if text.match?(NON_PAY_HINT)
      score
    end

    def params_in(op, location)
      (op['parameters'] || []).map { |p| resolve_ref_node(p) }.select { |p| p['in'] == location }
    end

    def request_schema(op)
      return nil unless op

      body = resolve_ref_node(op['requestBody'])
      dig(body, 'content', 'application/json', 'schema')
    end

    # --- auth ------------------------------------------------------------

    def build_auth(create)
      schemes = dig(@doc, 'components', 'securitySchemes') || {}

      # overrides.security_scheme — форсируем именованную схему: для спек с
      # несколькими схемами (Adyen: ApiKey/BasicAuth) или без явного security
      # на операции (Klarna). Override приоритетнее спеки.
      forced = @overrides['security_scheme']
      if forced
        return auth_from_scheme(schemes[forced], forced) if schemes[forced]

        @report.warn("overrides.security_scheme: схема '#{forced}' не найдена в securitySchemes — использую спеку.")
      end

      requirement = security_requirement(create)

      # Явный security: [] — операция без авторизации.
      return nil if requirement.is_a?(Array) && requirement.empty?

      scheme_name = requirement && requirement.first.is_a?(Hash) ? requirement.first.keys.first : nil
      scheme = scheme_name && schemes[scheme_name]
      if scheme.nil?
        @report.warn('Не удалось определить схему авторизации из security — заголовки будут пустыми')
        return nil
      end

      auth_from_scheme(scheme, scheme_name)
    end

    # Строит IR::Auth из объекта securityScheme (общий путь для спеки и override).
    def auth_from_scheme(scheme, scheme_name = nil)
      return nil unless scheme.is_a?(Hash)

      header, field, value = auth_shape(scheme)
      return nil if header.nil? && value.nil? # неподдержанная схема

      IR::Auth.new(
        scheme_type: scheme['type'],
        location: scheme['in'],
        header_name: header,
        credentials_field: field,
        header_value_ruby: value,
        http_scheme: http_scheme(scheme),
        spec_line: scheme_name && @line_index&.line_for('components', 'securitySchemes', scheme_name)
      )
    end

    # security операции, затем глобальный security (учитывая явный []).
    def security_requirement(create)
      op_sec = create && @doc.dig('paths', create.path, create.http_method, 'security')
      return op_sec unless op_sec.nil?

      @doc['security']
    end

    # Успешные коды создания берём из спеки (не хардкодим 201).
    def create_success_codes(create)
      return [] unless create

      create.response_codes.map(&:to_i).select { |c| c.between?(200, 299) }.sort
    end

    # Явная подсхема http (basic|bearer) — чтобы verifier не угадывал по credentials_field.
    def http_scheme(scheme)
      return nil unless scheme['type'] == 'http'

      scheme['scheme'].to_s.downcase == 'basic' ? 'basic' : 'bearer'
    end

    # По типу схемы возвращает [имя заголовка, поле credentials, Ruby-выражение значения].
    def auth_shape(scheme)
      case scheme['type']
      when 'apiKey'
        # in header или in query — оба поддержаны (location несёт scheme['in'])
        [scheme['name'], 'api_key', "provider.credentials.fetch('api_key')"]
      when 'http'
        if scheme['scheme'].to_s.downcase == 'basic'
          basic = %q{"Basic #{Base64.strict_encode64("#{provider.credentials.fetch('username')}:#{provider.credentials.fetch('password')}")}"}
          ['Authorization', 'password', basic]
        else # bearer — дефолт для http
          ['Authorization', 'token', %q{"Bearer #{provider.credentials.fetch('token')}"}]
        end
      else
        @report.warn("Схема авторизации '#{scheme['type']}' не поддержана — " \
                     'заголовки пустые, настройте авторизацию вручную')
        [nil, nil, nil]
      end
    end

    def idempotency_header(endpoints)
      endpoints.flat_map(&:header_params)
               .compact
               .map { |p| p['name'] }
               .find { |n| n.to_s.match?(/idempotency/i) } ||
        create_idempotency_param(endpoints)
    end

    def create_idempotency_param(endpoints)
      create = endpoints.find { |e| e.role == :create }
      return nil unless create

      names = ((@doc.dig('paths', create.path, create.http_method, 'parameters')) || [])
              .map { |p| resolve_ref_node(p)['name'] }
      names.find { |n| n.to_s.match?(/idempotency/i) }
    end

    # --- статусы и ошибки ------------------------------------------------

    def extract_status_enum(create, status)
      schema = success_response_schema(status) || success_response_schema(create)
      schema = resolve_deep(schema)
      enum = dig(schema, 'properties', 'status', 'enum')
      if enum.nil? || enum.empty?
        @report.warn('Не найден enum статусов в ответах — маппинг статусов пуст')
        return []
      end
      enum
    end

    def success_response_schema(endpoint)
      return nil unless endpoint

      responses = @doc.dig('paths', endpoint.path, endpoint.http_method, 'responses') || {}
      code = responses.keys.find { |c| c.to_s.start_with?('2') }
      return nil unless code

      response = resolve_ref_node(responses[code])
      dig(response, 'content', 'application/json', 'schema')
    end

    def collect_http_codes(endpoints)
      endpoints.flat_map(&:response_codes).map(&:to_i).uniq
    end

    # --- webhook ---------------------------------------------------------

    def build_webhook(endpoint, status_map)
      return nil unless endpoint

      schema = resolve_deep(endpoint.request_schema)
      events = dig(schema, 'properties', 'event', 'enum') || []
      sig    = endpoint.header_params.find { |p| p['name'].to_s.match?(/signature/i) }
      desc   = @doc.dig('paths', endpoint.path, endpoint.http_method, 'description').to_s
      alg    = desc[/HMAC-SHA\d+/i] || (sig && sig['description'].to_s[/HMAC-SHA\d+/i]) || 'HMAC-SHA256'

      @report.warn('Webhook без заголовка подписи — верификация невозможна') if sig.nil?

      IR::Webhook.new(
        path: endpoint.path,
        events: events,
        event_actions: event_actions(events, status_map),
        id_field: webhook_id_field(schema),
        signature_header: sig && sig['name'],
        signature_alg: alg.sub(/HMAC-/i, ''),
        signature_encoding: signature_encoding(sig),
        callback_secret_field: 'callback_secret'
      )
    end

    # Кодировку подписи (hex/base64) OpenAPI обычно не выражает — берём из
    # overrides либо предупреждаем и принимаем 'hex' (канон NovaPay).
    def signature_encoding(sig)
      override = @overrides['signature_encoding']
      return override if override
      return nil if sig.nil?

      @report.warn(
        "Кодировка подписи webhook не задана в спеке: принята 'hex'. " \
        'Уточните overrides.signature_encoding при необходимости.'
      )
      'hex'
    end

    # Поле-идентификатор операции в теле webhook (напр. payout_id).
    def webhook_id_field(schema)
      required = dig(schema, 'required') || []
      candidate = (required - %w[event status]).reject { |f| f.to_s.match?(/external/) }.first
      candidate || 'id'
    end

    def event_actions(events, status_map)
      events.each_with_object({}) do |event, acc|
        status_key = event.to_s.split('.').last
        internal = status_map[status_key] || status_map[status_key.to_s]
        acc[event] = case internal
                     when 'approved', 'in_progress' then :approve
                     when 'rejected', 'refunded'    then :reject
                     else :unknown
                     end
      end
    end

    # --- примеры для fixtures --------------------------------------------

    def request_examples(create)
      return {} unless create

      operation = @doc.dig('paths', create.path, create.http_method)
      body = resolve_ref_node(operation && operation['requestBody'])
      media_examples(dig(body, 'content', 'application/json'))
    end

    def response_examples(create, status)
      out = {}
      [create, status].compact.each do |endpoint|
        responses = @doc.dig('paths', endpoint.path, endpoint.http_method, 'responses') || {}
        responses.each do |code, body|
          media = dig(resolve_ref_node(body), 'content', 'application/json')
          ex = media_examples(media).values.first
          out["#{endpoint.role}_#{code}"] = ex unless ex.nil?
        end
      end
      out
    end

    def webhook_examples(endpoint)
      return {} unless endpoint

      operation = @doc.dig('paths', endpoint.path, endpoint.http_method)
      body = resolve_ref_node(operation && operation['requestBody'])
      media_examples(dig(body, 'content', 'application/json'))
    end

    # OpenAPI разрешает как один `example`, так и именованный объект `examples`.
    # Возвращаем одинаковую внутреннюю форму и разворачиваем локальные Example refs.
    def media_examples(media)
      return {} unless media.is_a?(Hash)

      named = media['examples']
      if named.is_a?(Hash)
        return named.each_with_object({}) do |(name, entry), out|
          resolved = resolve_ref_node(entry)
          out[name] = resolved['value'] if resolved.is_a?(Hash) && resolved.key?('value')
        end
      end

      media.key?('example') ? { 'default' => media['example'] } : {}
    end

    # --- служебное -------------------------------------------------------

    def base_url
      servers = @doc['servers'] || []
      sandbox = servers.find { |s| s['description'].to_s.match?(/sandbox|test/i) }
      url = (sandbox || servers.first || {})['url']
      @report.warn('В спецификации не указаны servers — BASE_URL пуст') if url.nil?
      url
    end

    def resolve_ref_node(node)
      return node unless node.is_a?(Hash) && node['$ref']

      resolve_ref(node['$ref'])
    end

    def resolve_ref(ref)
      unless ref.to_s.start_with?('#/')
        warn_once("Внешняя ссылка #{ref.inspect} не поддержана — часть схемы не развёрнута")
        return nil
      end

      parts = ref.sub(%r{^#/}, '').split('/')
      parts.reduce(@doc) { |acc, key| acc.is_a?(Hash) ? acc[key] : nil }
    end

    # Бюджет обхода и глубины: на огромных спеках (Stripe) плотный граф $ref даёт
    # комбинаторный разворот. Ограничиваем — незавершённые ветки остаются как есть
    # (это лишь добавит честных предупреждений о несопоставленных полях).
    RESOLVE_NODE_BUDGET = 50_000
    RESOLVE_MAX_DEPTH   = 40

    # Глубоко разворачивает $ref внутри схемы (с защитой от циклов и бюджетом).
    def resolve_deep(node, seen = [], depth = 0)
      @resolve_budget = RESOLVE_NODE_BUDGET if seen.empty? && depth.zero?
      if @resolve_budget.nil? || @resolve_budget <= 0
        warn_once('Бюджет разворота $ref исчерпан — часть схемы не развёрнута')
        return node
      end
      if depth > RESOLVE_MAX_DEPTH
        warn_once('Максимальная глубина разворота $ref исчерпана — часть схемы не развёрнута')
        return node
      end

      @resolve_budget -= 1

      case node
      when Hash
        warn_unsupported_combinators(node)
        if node['$ref']
          ref = node['$ref']
          if seen.include?(ref)
            warn_once("Циклическая ссылка #{ref.inspect} не развёрнута")
            return {}
          end

          resolved = resolve_ref(ref)
          if resolved.nil?
            warn_once("Ссылка #{ref.inspect} не найдена или не поддержана — часть схемы не развёрнута")
            return {}
          end

          resolve_deep(resolved, seen + [ref], depth + 1)
        elsif node['allOf'].is_a?(Array)
          merge_all_of(node, seen, depth)
        else
          node.each_with_object({}) { |(k, v), acc| acc[k] = resolve_deep(v, seen, depth + 1) }
        end
      when Array
        node.map { |v| resolve_deep(v, seen, depth + 1) }
      else
        node
      end
    end

    # Простое слияние allOf: объединяем properties/required, наследуем type/enum.
    # Полный oneOf/anyOf не обещаем — но allOf на реальных спеках встречается часто.
    def merge_all_of(node, seen, depth)
      merged = {}
      node['allOf'].each do |member|
        resolved = resolve_deep(member, seen, depth + 1)
        merged = merge_schema(merged, resolved) if resolved.is_a?(Hash)
      end
      node.each do |key, value|
        next if key == 'allOf' || merged.key?(key)

        merged[key] = resolve_deep(value, seen, depth + 1)
      end
      merged
    end

    def merge_schema(base, add)
      result = base.dup
      add.each do |key, value|
        result[key] =
          if key == 'properties' && base['properties'].is_a?(Hash) && value.is_a?(Hash)
            base['properties'].merge(value)
          elsif key == 'required' && base['required'].is_a?(Array) && value.is_a?(Array)
            (base['required'] + value).uniq
          else
            value
          end
      end
      result
    end

    def warn_ambiguous_endpoints(label, endpoints)
      return unless endpoints.size > 1

      choices = endpoints.map { |endpoint| "#{endpoint.http_method.upcase} #{endpoint.path}" }.join(', ')
      @report.warn("Найдено несколько методов #{label}: #{choices}. Использован первый; при необходимости выберите endpoint вручную.")
    end

    def warn_unsupported_combinators(node)
      %w[oneOf anyOf].each do |key|
        next unless node[key].is_a?(Array)

        warn_once("#{key} пока не разворачивается автоматически — проверьте маппинг полей вручную")
      end
    end

    def warn_once(message)
      @warned_messages ||= {}
      return if @warned_messages[message]

      @warned_messages[message] = true
      @report.warn(message)
    end

    def dig(node, *keys)
      keys.reduce(node) { |acc, key| acc.is_a?(Hash) ? acc[key] : nil }
    end

    def camelize(str)
      str.to_s.split(/[_\-\s]+/).map { |p| p.capitalize }.join
    end
  end
end
