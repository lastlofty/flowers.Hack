# frozen_string_literal: true

require 'minitest/autorun'
require 'json'
require_relative '../lib/paybridge'

# Доказательство универсальности: то же ядро, без единой правки кода,
# разбирает и генерирует интеграцию для ДРУГОГО провайдера (BluePay),
# отличающегося набором методов, полей, авторизацией и статусами.
class TestUniversality < Minitest::Test
  def setup
    spec_path = File.expand_path('../examples/bluepay_api.yaml', __dir__)
    @config = Paybridge.load_config
    @spec = Paybridge::SpecParser.new(spec_path, 'bluepay', @config).parse
  end

  def test_endpoints_differ_from_novapay
    assert_equal 3, @spec.endpoints.size
    roles = @spec.endpoints.map(&:role)
    assert_includes roles, :create
    assert_includes roles, :status
    assert_includes roles, :webhook
    refute_includes roles, :cancel          # у BluePay нет отмены
    assert_nil @spec.cancel_endpoint
  end

  def test_auth_adapts
    assert_equal 'X-Api-Token', @spec.auth.header_name
    assert_equal 'api_key', @spec.auth.credentials_field
  end

  def test_no_idempotency
    assert_nil @spec.idempotency_header
  end

  def test_status_map_uses_new_vocabulary
    assert_equal 'in_progress', @spec.status_map['created']
    assert_equal 'in_progress', @spec.status_map['sent']
    assert_equal 'approved', @spec.status_map['done']
    assert_equal 'rejected', @spec.status_map['failed']
  end

  def test_amount_cents_and_reference
    assert @spec.amount[:minor_units]
    assert_equal 1, @spec.amount[:min_major]         # 100 центов -> 1 USD
    assert_equal 'USD', @spec.currency
    assert_equal 'reference', @spec.external_id_field
  end

  def test_card_payload
    assert_includes @spec.request_payload_ruby, '(operation.amount * 100).to_i'
    assert_includes @spec.request_payload_ruby, "requisite.dig('card', 'card_number')"
  end

  def test_webhook_sha512
    assert_equal 'X-BluePay-Signature', @spec.webhook.signature_header
    assert_equal 'SHA512', @spec.webhook.signature_alg
    assert_equal 'transfer_id', @spec.webhook.id_field
    assert_equal :approve, @spec.webhook.event_actions['transfer.done']
    assert_equal :reject, @spec.webhook.event_actions['transfer.failed']
  end

  def test_generated_service_is_provider_specific
    code = Paybridge::Generators::ServiceGenerator.new(@spec, config: @config).render
    assert_includes code, 'class BluepayService < BaseService'
    assert_includes code, "BASE_URL = ENV.fetch('BLUEPAY_BASE_URL'"
    assert_includes code, 'MIN_AMOUNT = 1'
    assert_includes code, "'X-Api-Token' => provider.credentials.fetch('api_key')"
    assert_includes code, "OpenSSL::HMAC.hexdigest('SHA512'"
    assert_includes code, 'when 201'

    # у BluePay нет idempotency — метод и заголовок не должны генерироваться
    refute_includes code, 'Idempotency-Key'
    refute_includes code, 'def idempotency_key'
    refute_includes code, 'when 201, 409'
  end

  def test_generation_produces_all_artifacts
    generation = Paybridge.generate(
      spec_path: File.expand_path('../examples/bluepay_api.yaml', __dir__),
      provider: 'bluepay'
    )
    assert_equal %w[bluepay_service.rb INTEGRATION.md fixtures.json].sort,
                 generation.files.keys.sort
    assert_empty generation.warnings   # все статусы/коды известны конфигу
  end
end
