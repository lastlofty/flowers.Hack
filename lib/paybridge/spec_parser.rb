# frozen_string_literal: true

require 'yaml'
require_relative 'ir'
require_relative 'report'
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

    def parse
      @doc = load_yaml
      validate_openapi!

      endpoints = build_endpoints
      create    = endpoints.find { |e| e.role == :create }
      status    = endpoints.find { |e| e.role == :status }
      cancel    = endpoints.find { |e| e.role == :cancel }
      webhook_e = endpoints.find { |e| e.role == :webhook }

      @report.warn('Не найден метод создания операции (POST) — сервис будет неполным') if create.nil?
      @report.warn('Не найден метод статус-запроса (GET {id})') if status.nil?

      status_enum = extract_status_enum(create, status)
      http_codes  = collect_http_codes(endpoints)

      status_map = Mappers::StatusMapper.new(@config, @report).build(status_enum)
      error_mapper = Mappers::ErrorMapper.new(@config, @report)
      error_map, http_symbol = error_mapper.build(http_codes)

      req_schema = create && resolve_deep(create.request_schema)
      req = Mappers::RequestMapper.new(@report, @overrides).build(req_schema)

      IR::Spec.new(
        provider_name: @provider,
        provider_class: camelize(@provider) + 'Service',
        title: dig(@doc, 'info', 'title'),
        version: dig(@doc, 'info', 'version'),
        base_url: base_url,
        base_url_env: "#{@provider.upcase}_BASE_URL",
        auth: build_auth,
        idempotency_header: idempotency_header(endpoints),
        endpoints: endpoints,
        create_endpoint: create,
        status_endpoint: status,
        cancel_endpoint: cancel,
        webhook: build_webhook(webhook_e, status_map),
        status_map: status_map,
        error_map: error_map,
        http_symbol: http_symbol,
        amount: req.amount,
        currency: req.currency,
        external_id_field: req.external_id_field,
        request_payload_ruby: req.ruby,
        request_examples: request_examples(create),
        response_examples: response_examples(create, status),
        webhook_examples: webhook_examples(webhook_e),
        report: @report
      )
    end

    private

    def load_yaml
      raise ParseError, "Файл спецификации не найден: #{@spec_path}" unless File.exist?(@spec_path)

      YAML.safe_load(File.read(@spec_path), aliases: true)
    rescue Psych::SyntaxError => e
      raise ParseError, "Некорректный YAML: #{e.message}"
    end

    def validate_openapi!
      return if @doc.is_a?(Hash) && (@doc['openapi'] || @doc['swagger'])

      raise ParseError, 'Это не похоже на OpenAPI-спецификацию (нет ключа openapi/swagger)'
    end

    # --- endpoints -------------------------------------------------------

    def build_endpoints
      paths = @doc['paths'] || {}
      endpoints = []
      paths.each do |path, methods|
        next unless methods.is_a?(Hash)

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
            response_codes: (op['responses'] || {}).keys
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

    def params_in(op, location)
      (op['parameters'] || []).map { |p| resolve_ref_node(p) }.select { |p| p['in'] == location }
    end

    def request_schema(op)
      return nil unless op

      dig(op, 'requestBody', 'content', 'application/json', 'schema')
    end

    # --- auth ------------------------------------------------------------

    def build_auth
      schemes = dig(@doc, 'components', 'securitySchemes') || {}
      name, scheme = schemes.first
      if scheme.nil?
        @report.warn('В спецификации не описаны securitySchemes — авторизация не сгенерирована')
        return nil
      end

      IR::Auth.new(
        scheme_type: scheme['type'],
        location: scheme['in'],
        header_name: scheme['name'],
        credentials_field: credentials_field(name, scheme)
      )
    end

    def credentials_field(_name, scheme)
      case scheme['type']
      when 'apiKey' then 'api_key'
      when 'http'   then scheme['scheme'] == 'bearer' ? 'token' : 'password'
      else 'api_key'
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

      dig(responses[code], 'content', 'application/json', 'schema')
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

      examples = dig(@doc.dig('paths', create.path, create.http_method),
                     'requestBody', 'content', 'application/json', 'examples') || {}
      examples.transform_values { |e| e['value'] }
    end

    def response_examples(create, status)
      out = {}
      [create, status].compact.each do |endpoint|
        responses = @doc.dig('paths', endpoint.path, endpoint.http_method, 'responses') || {}
        responses.each do |code, body|
          ex = dig(resolve_ref_node(body), 'content', 'application/json', 'example')
          out["#{endpoint.role}_#{code}"] = ex if ex
        end
      end
      out
    end

    def webhook_examples(endpoint)
      return {} unless endpoint

      examples = dig(@doc.dig('paths', endpoint.path, endpoint.http_method),
                     'requestBody', 'content', 'application/json', 'examples') || {}
      examples.transform_values { |e| e['value'] }
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
      parts = ref.sub(%r{^#/}, '').split('/')
      parts.reduce(@doc) { |acc, key| acc.is_a?(Hash) ? acc[key] : nil }
    end

    # Глубоко разворачивает $ref внутри схемы (с защитой от циклов).
    def resolve_deep(node, seen = [])
      case node
      when Hash
        if node['$ref']
          ref = node['$ref']
          return {} if seen.include?(ref)

          resolve_deep(resolve_ref(ref), seen + [ref])
        else
          node.each_with_object({}) { |(k, v), acc| acc[k] = resolve_deep(v, seen) }
        end
      when Array
        node.map { |v| resolve_deep(v, seen) }
      else
        node
      end
    end

    def dig(node, *keys)
      keys.reduce(node) { |acc, key| acc.is_a?(Hash) ? acc[key] : nil }
    end

    def camelize(str)
      str.to_s.split(/[_\-\s]+/).map { |p| p.capitalize }.join
    end
  end
end
