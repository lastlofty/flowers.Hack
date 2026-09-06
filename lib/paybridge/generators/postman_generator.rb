# frozen_string_literal: true

require 'json'

module Paybridge
  module Generators
    # `<provider>.postman_collection.json` — коллекция Postman v2.1: create / status /
    # cancel / webhook как готовые запросы с авторизацией и примером тела. Импортируешь
    # в Postman (или Insomnia/Bruno — совместимый формат) и сразу бьёшь в песочницу
    # провайдера, не собирая запросы руками. Переменные ({{base_url}}, {{api_key}} …)
    # заполняются в окружении Postman.
    #
    # Детерминирован (упорядоченный JSON) — годится в golden.
    class PostmanGenerator
      SCHEMA = 'https://schema.getpostman.com/json/collection/v2.1.0/collection.json'

      attr_reader :spec

      def initialize(spec, **_opts)
        @spec = spec
      end

      def filename
        "#{spec.provider_name}.postman_collection.json"
      end

      def render
        "#{JSON.pretty_generate(collection)}\n"
      end

      private

      def collection
        {
          'info' => {
            'name' => "#{spec.provider_name} — интеграция (PayBridge)",
            'schema' => SCHEMA
          },
          'variable' => variables,
          'item' => items
        }
      end

      def variables
        vars = [{ 'key' => 'base_url', 'value' => spec.base_url.to_s }]
        vars << { 'key' => credential_var, 'value' => '' } if credential_var
        vars << { 'key' => 'provider_operation_id', 'value' => 'op_test' }
        vars
      end

      def items
        list = []
        list << request_item('Создание операции', 'POST', spec.create_endpoint, body: true) if spec.create_endpoint
        list << request_item('Статус операции', 'GET', spec.status_endpoint) if spec.status_endpoint
        list << request_item('Отмена', 'POST', spec.cancel_endpoint) if spec.cancel_endpoint
        list << webhook_item if spec.webhook
        list
      end

      def request_item(name, method, endpoint, body: false)
        request = {
          'method' => method,
          'header' => headers(body),
          'url' => url_object(endpoint.path)
        }
        request['body'] = raw_body if body
        { 'name' => name, 'request' => request }
      end

      # Webhook — это входящий запрос ОТ провайдера; кладём как пример POST на
      # ваш обработчик с телом уведомления (чтобы протестировать приём локально).
      def webhook_item
        example = spec.webhook_examples.values.first || {}
        {
          'name' => 'Webhook (входящее уведомление, пример)',
          'request' => {
            'method' => 'POST',
            'header' => [content_type_header],
            'url' => url_object(spec.webhook.path),
            'body' => { 'mode' => 'raw', 'raw' => pretty_json(example),
                        'options' => { 'raw' => { 'language' => 'json' } } }
          }
        }
      end

      def headers(body)
        list = []
        list << content_type_header if body
        list.concat(auth_headers)
        list << { 'key' => spec.idempotency_header, 'value' => '{{idempotency_key}}' } if body && spec.idempotency_header
        list
      end

      def content_type_header
        { 'key' => 'Content-Type', 'value' => 'application/json' }
      end

      # Заголовок авторизации в терминах Postman-переменных (значения — в окружении).
      def auth_headers
        return [] unless spec.auth && spec.auth.location != 'query'

        value =
          case spec.auth.scheme_type
          when 'apiKey' then "{{#{credential_var}}}"
          when 'http'   then spec.auth.http_scheme == 'basic' ? 'Basic {{basic_auth}}' : 'Bearer {{token}}'
          when 'oauth2', 'openIdConnect' then 'Bearer {{token}}'
          end
        value ? [{ 'key' => spec.auth.header_name, 'value' => value }] : []
      end

      def credential_var
        return nil unless spec.auth

        case spec.auth.scheme_type
        when 'apiKey' then 'api_key'
        when 'http'   then spec.auth.http_scheme == 'basic' ? 'basic_auth' : 'token'
        when 'oauth2', 'openIdConnect' then 'token'
        end
      end

      def raw_body
        example = spec.request_examples.values.first || {}
        { 'mode' => 'raw', 'raw' => pretty_json(example),
          'options' => { 'raw' => { 'language' => 'json' } } }
      end

      # Детерминированный pretty-JSON: JSON.pretty_generate по-разному печатает
      # ПУСТЫЕ контейнеры в C-расширении ("{}") и чистом Ruby ("{\n}") — из-за
      # этого golden «дрейфовал» между CI и Windows. Нормализуем пустые до "{}".
      def pretty_json(obj)
        return '{}' if obj.is_a?(Hash) && obj.empty?
        return '[]' if obj.is_a?(Array) && obj.empty?

        JSON.pretty_generate(obj)
      end

      # {payment_id} -> {{provider_operation_id}}; query-авторизация добавляется в URL.
      def url_object(path)
        rendered = path.to_s.gsub(/\{[^}]+\}/, '{{provider_operation_id}}')
        raw = "{{base_url}}#{rendered}"
        query = auth_query
        raw += (raw.include?('?') ? '&' : '?') + query if query
        { 'raw' => raw, 'host' => ['{{base_url}}'], 'path' => rendered.split('/').reject(&:empty?) }
      end

      def auth_query
        return nil unless spec.auth && spec.auth.location == 'query'

        "#{spec.auth.header_name}={{#{credential_var || 'api_key'}}}"
      end
    end
  end
end
