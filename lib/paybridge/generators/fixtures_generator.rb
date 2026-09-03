# frozen_string_literal: true

require 'json'

module Paybridge
  module Generators
    # Генерирует fixtures.json: примеры запросов, ответов и уведомлений,
    # извлечённые из спецификации, с ожидаемыми результатами маппинга.
    class FixturesGenerator
      attr_reader :spec

      def initialize(spec, **_opts)
        @spec = spec
      end

      def filename
        'fixtures.json'
      end

      def render
        JSON.pretty_generate(build) + "\n"
      end

      private

      def build
        data = { 'provider' => spec.provider_name }
        data['base_url'] = spec.base_url if spec.base_url
        data['auth'] = auth_block if spec.auth
        data['create_request'] = create_block if spec.create_endpoint
        data['fetch_status'] = status_block if spec.status_endpoint
        data['callback'] = callback_block if spec.webhook
        data
      end

      def auth_block
        {
          'type' => spec.auth.scheme_type,
          'header' => spec.auth.header_name,
          'credentials_field' => spec.auth.credentials_field
        }
      end

      def create_block
        block = { 'endpoint' => "POST #{spec.create_endpoint.path}" }
        request = spec.request_examples.values.first
        block['request'] = request if request

        spec.response_examples.each do |key, example|
          next unless key.start_with?('create_')

          code = key.split('_').last
          block["response_#{code}"] = example
          block["expected_#{code}"] = expected_for(code, example)
        end
        block
      end

      def status_block
        block = { 'endpoint' => "GET #{spec.status_endpoint.path}" }
        spec.response_examples.each do |key, example|
          next unless key.start_with?('status_')

          code = key.split('_').last
          block["response_#{code}"] = example
          if example.is_a?(Hash) && example['status']
            block["expected_#{code}"] = { 'status' => 'success',
                                          'operation_status' => spec.status_map[example['status']] }
          end
        end
        block
      end

      def callback_block
        block = { 'endpoint' => "POST #{spec.webhook.path}" }
        block['signature_header'] = spec.webhook.signature_header if spec.webhook.signature_header

        spec.webhook_examples.each do |name, payload|
          entry = { 'payload' => payload }
          status = payload.is_a?(Hash) ? payload['status'] : nil
          entry['expected_operation_status'] = spec.status_map[status] if status && spec.status_map[status]
          block[name] = entry
        end
        block
      end

      def expected_for(code, example)
        if code == '201' && example.is_a?(Hash)
          { 'status' => 'success',
            'provider_operation_id' => example['id'],
            'operation_status' => spec.status_map[example['status']] }
        elsif example.is_a?(Hash) && example['error']
          { 'status' => 'failed', 'provider_code' => example.dig('error', 'code') }
        else
          {}
        end
      end
    end
  end
end
