# frozen_string_literal: true

require 'erb'
require_relative '../safe'

module Paybridge
  module Generators
    # Общий рендер ERB-шаблонов и хелперы, используемые внутри шаблонов.
    class BaseGenerator
      TEMPLATES_DIR = File.expand_path('../templates', __dir__)

      attr_reader :spec, :spec_source, :config

      def initialize(spec, spec_source: 'provider_api.yaml', config: {})
        @spec = spec
        @spec_source = spec_source
        @config = config
      end

      def render_template(name)
        template = File.read(File.join(TEMPLATES_DIR, name))
        ERB.new(template, trim_mode: '-').result(binding)
      end

      # --- хелперы шаблонов -------------------------------------------------

      def min_amount
        spec.amount && spec.amount[:min_native]
      end

      # Выражение для проверки минимума в корректных единицах (без деления).
      def amount_too_low_condition
        if spec.amount && spec.amount[:minor_units]
          'amount_in_minor_units(operation.amount) < MIN_AMOUNT'
        else
          'operation.amount < MIN_AMOUNT'
        end
      end

      # Нужен ли require 'base64' в сгенерированном сервисе
      # (подпись webhook в base64 или Basic-авторизация).
      def needs_base64?
        webhook_base64 = spec.webhook && spec.webhook.signature_encoding == 'base64'
        auth_base64 = spec.auth && spec.auth.header_value_ruby.to_s.include?('Base64')
        webhook_base64 || auth_base64
      end

      # --- выбор способа выплаты (sbp/card) ---

      def recipient_spec?
        !spec.recipient_spec.nil?
      end

      def payout_methods
        recipient_spec? ? spec.recipient_spec['methods'] : {}
      end

      def payout_methods_literal
        Safe.string_array(payout_methods.keys)
      end

      # Литерал REQUIRED_REQUISITE = { 'sbp' => %w[phone bank_code], ... }
      def required_requisite_literal
        entries = payout_methods.map do |method, info|
          "      #{Safe.rb(method)} => #{Safe.string_array(info['required'])}"
        end
        "{\n#{entries.join(",\n")}\n    }.freeze"
      end

      # Тело ветки case для одного способа: { type:, поля через requisite.dig }.compact
      def recipient_branch(method, info)
        pairs = ["type: #{Safe.rb(method)}"]
        info['fields'].each do |field|
          pairs << "#{Safe.hash_key(field)} requisite.dig(#{Safe.rb(method)}, #{Safe.rb(field)})"
        end
        "{ #{pairs.join(', ')} }.compact"
      end

      # apiKey передаётся в query-параметре, а не в заголовке.
      def auth_in_query?
        spec.auth && spec.auth.location == 'query'
      end

      # Фрагмент для добавления ключа в URL при query-авторизации (иначе '').
      # Имя параметра и значение экранируются CGI.escape в рантайме.
      def auth_query
        return '' unless auth_in_query?

        "?\#{CGI.escape(#{Safe.rb(spec.auth.header_name)})}=\#{CGI.escape(#{spec.auth.header_value_ruby})}"
      end

      def render_status_map
        render_const('STATUS_MAP', spec.status_map) { |k, v| "#{Safe.rb(k)} => #{Safe.rb(v)}" }
      end

      def render_error_map
        render_const('ERROR_MAP', spec.error_map) { |k, v| "#{k.to_i} => #{Safe.rb(v)}" }
      end

      def render_symbol_map
        render_const('HTTP_STATUS_SYMBOL', spec.http_symbol) { |k, v| "#{k.to_i} => #{Safe.sym(v)}" }
      end

      def create_headers
        if spec.idempotency_header
          "auth_headers.merge(#{Safe.rb(spec.idempotency_header)} => idempotency_key(operation))"
        else
          'auth_headers'
        end
      end

      def status_path_ruby
        return '' unless spec.status_endpoint

        spec.status_endpoint.path.gsub(/\{[^}]+\}/, '#{operation.provider_operation_id}')
      end

      def approve_events
        return [] unless spec.webhook

        spec.webhook.event_actions.select { |_, action| action == :approve }.keys
      end

      def reject_events
        return [] unless spec.webhook

        spec.webhook.event_actions.select { |_, action| action == :reject }.keys
      end

      def create_success_codes
        codes = (spec.create_success_codes || []).dup
        codes = [201] if codes.empty? # спека без 2xx — минимальный дефолт
        codes.join(', ')
      end

      def idempotent_conflict?
        spec.idempotency_header &&
          spec.create_endpoint &&
          spec.create_endpoint.response_codes.map(&:to_i).include?(409)
      end

      def error_action(http)
        entry = (config['error_map'] || {})[http.to_s] || {}
        entry['action'] || '—'
      end

      def method_rows
        rows = []
        if spec.create_endpoint
          rows << row('create_request', spec.create_endpoint, 'Создание операции',
                      spec.idempotency_header ? "`#{spec.idempotency_header}` header" : '—')
        end
        rows << row('fetch_status', spec.status_endpoint, 'Статус', '—') if spec.status_endpoint
        rows << row('(отмена)', spec.cancel_endpoint, 'Отмена', '—') if spec.cancel_endpoint
        if spec.webhook
          rows << { service: 'process_callback', endpoint: "POST `#{spec.webhook.path}`",
                    purpose: 'Callback',
                    idempotency: spec.webhook.signature_header ? "`#{spec.webhook.signature_header}`" : '—' }
        end
        rows
      end

      private

      def row(service, endpoint, purpose, idempotency)
        { service: service,
          endpoint: "#{endpoint.http_method.upcase} `#{endpoint.path}`",
          purpose: endpoint.summary || purpose,
          idempotency: idempotency }
      end

      # Формирует блок вида:
      #     NAME = {
      #       key => value,
      #     }.freeze
      def render_const(name, map)
        return "    #{name} = {}.freeze" if map.empty?

        entries = map.map { |k, v| "      #{yield(k, v)}" }.join(",\n")
        "    #{name} = {\n#{entries}\n    }.freeze"
      end
    end
  end
end
