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
        "#{JSON.pretty_generate(build)}\n"
      end

      private

      def build
        data = { 'contract_version' => 2, 'provider' => spec.provider_name }
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
          'location' => spec.auth.location,
          'header' => spec.auth.header_name,
          'credentials_field' => spec.auth.credentials_field
        }
      end

      def create_block
        block = { 'endpoint' => "POST #{spec.create_endpoint.path}" }
        block['idempotency_header'] = spec.idempotency_header if spec.idempotency_header
        request = spec.request_examples.values.first
        if request
          block['request'] = request
          block['request_source'] = 'openapi'
          block['operation'] = operation_for(request)
        end

        spec.response_examples.each do |key, example|
          next unless key.start_with?('create_')

          code = key.split('_').last
          next if code == '409' && idempotent_conflict?

          block["response_#{code}"] = example
          block["expected_#{code}"] = expected_for(code, example)
          block["source_#{code}"] = 'openapi'
        end
        synthesize_create_example(block)
        add_idempotency_scenarios(block) if idempotent_conflict?
        block
      end

      # Если в спеке нет inline-примера успешного создания, синтезируем его из
      # enum статусов — чтобы create можно было проверить даже на «сухой» спеке.
      def synthesize_create_example(block)
        code = (spec.create_success_codes || []).first || 201
        return if block["response_#{code}"]

        provider_status = spec.status_map.key('in_progress') || spec.status_map.keys.first
        return unless provider_status

        block["response_#{code}"] = { 'id' => 'op_sample', 'status' => provider_status }
        block["expected_#{code}"] = {
          'status' => 'success',
          'provider_operation_id' => 'op_sample',
          'operation_status' => spec.status_map[provider_status]
        }
        block["source_#{code}"] = 'synthetic'
      end

      def add_idempotency_scenarios(block)
        example = spec.response_examples['create_409']
        provider_status = spec.status_map.key('in_progress') || spec.status_map.keys.first
        idempotent = example if example.is_a?(Hash) && example['id'] && spec.status_map[example['status']]
        idempotent ||= { 'id' => 'op_duplicate', 'status' => provider_status } if provider_status
        if idempotent
          block['response_409_idempotent'] = idempotent
          block['expected_409_idempotent'] = {
            'status' => 'success', 'provider_operation_id' => idempotent['id'],
            'operation_status' => spec.status_map[idempotent['status']]
          }
          block['source_409_idempotent'] = example.equal?(idempotent) ? 'openapi' : 'synthetic'
        end

        conflict = example if example.is_a?(Hash) && example['error']
        conflict ||= { 'error' => { 'code' => 'conflict', 'message' => 'ordinary conflict' } }
        block['response_409_conflict'] = conflict
        block['expected_409_conflict'] = {
          'status' => 'failed', 'provider_code' => conflict.dig('error', 'code'),
          'internal_code' => spec.error_map[409]
        }
        block['source_409_conflict'] = example.equal?(conflict) ? 'openapi' : 'synthetic'
      end

      def idempotent_conflict?
        spec.idempotency_header && spec.create_endpoint.response_codes.map(&:to_i).include?(409)
      end

      def operation_for(request)
        amount = request['amount']
        amount /= 100.0 if amount && spec.amount && spec.amount[:minor_units]
        recipient = request['recipient']
        requisite = if recipient.is_a?(Hash) && recipient['type']
                      { recipient['type'] => recipient.reject { |key, _| key == 'type' } }
                    else
                      {}
                    end
        {
          'amount' => amount,
          'id' => request['external_id'] || request['reference'] || request['order_id'] || 'op_test',
          'payout_requisite' => requisite,
          'provider_operation_id' => 'op_prov',
          'idempotency_key' => 'idem_1'
        }
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
          elsif example.is_a?(Hash) && example['error']
            block["expected_#{code}"] = {
              'status' => 'failed', 'provider_code' => example.dig('error', 'code'),
              'internal_code' => spec.error_map[code.to_i]
            }
          end
          block["source_#{code}"] = 'openapi'
        end
        synthesize_status_example(block)
        block
      end

      # Если в спеке нет 2xx-примера со статусом, синтезируем его из enum статусов,
      # чтобы fetch_status можно было проверить (verify / сгенерированные тесты).
      def synthesize_status_example(block)
        return if block.keys.any? { |key| key.match?(/\Aexpected_2\d\d\z/) }

        provider_status = spec.status_map.key('approved') ||
                          spec.status_map.key('in_progress') ||
                          spec.status_map.keys.first
        return unless provider_status

        block['response_200'] = { 'id' => 'op_sample', 'status' => provider_status }
        block['expected_200'] = { 'status' => 'success',
                                  'operation_status' => spec.status_map[provider_status] }
        block['source_200'] = 'synthetic'
      end

      def callback_block
        block = { 'endpoint' => "POST #{spec.webhook.path}" }
        if spec.webhook.signature_header
          block['signature_header']   = spec.webhook.signature_header
          block['signature_alg']      = spec.webhook.signature_alg
          block['signature_encoding'] = spec.webhook.signature_encoding
        end

        spec.webhook_examples.each do |name, payload|
          entry = { 'payload' => payload, 'raw_body' => JSON.pretty_generate(payload), 'source' => 'openapi' }
          status = payload.is_a?(Hash) ? payload['status'] : nil
          entry['expected_operation_status'] = spec.status_map[status] if status && spec.status_map[status]
          block[name] = entry
        end
        block
      end

      def expected_for(code, example)
        if spec.create_success_codes.include?(code.to_i) && example.is_a?(Hash)
          { 'status' => 'success',
            'provider_operation_id' => example['id'],
            'operation_status' => spec.status_map[example['status']] }
        elsif example.is_a?(Hash) && example['error']
          { 'status' => 'failed',
            'provider_code' => example.dig('error', 'code'),
            'internal_code' => spec.error_map[code.to_i] }
        else
          {}
        end
      end
    end
  end
end
