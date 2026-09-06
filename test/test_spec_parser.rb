# frozen_string_literal: true

require 'minitest/autorun'
require 'tempfile'
require_relative '../lib/paybridge'

class TestSpecParser < Minitest::Test
  def setup
    spec_path = File.expand_path('../examples/provider_api.yaml', __dir__)
    config = Paybridge.load_config
    @spec = Paybridge::SpecParser.new(spec_path, 'novapay', config).parse
  end

  def test_endpoints_discovered
    assert_equal 5, @spec.endpoints.size
    roles = @spec.endpoints.map(&:role)
    assert_includes roles, :create
    assert_includes roles, :status
    assert_includes roles, :cancel
    assert_includes roles, :webhook
  end

  def test_auth
    assert_equal 'apiKey', @spec.auth.scheme_type
    assert_equal 'X-API-Key', @spec.auth.header_name
    assert_equal 'api_key', @spec.auth.credentials_field
  end

  def test_idempotency_detected
    assert_equal 'Idempotency-Key', @spec.idempotency_header
  end

  def test_status_map
    assert_equal 'in_progress', @spec.status_map['pending']
    assert_equal 'approved', @spec.status_map['completed']
    assert_equal 'rejected', @spec.status_map['failed']
    assert_equal 'rejected', @spec.status_map['cancelled']
  end

  def test_error_map
    assert_equal 'insufficient_balance', @spec.error_map[402]
    assert_equal 'rate_limit', @spec.error_map[429]
    assert_equal 'validation_error', @spec.error_map[422]
  end

  def test_amount_conversion
    assert @spec.amount[:minor_units]
    assert_equal 100_000, @spec.amount[:min_native]
  end

  def test_currency
    assert_equal 'RUB', @spec.currency
  end

  def test_request_payload_literal
    assert_includes @spec.request_payload_ruby, 'amount_in_minor_units(operation.amount)'
    # recipient с несколькими способами -> выбор в рантайме через build_recipient
    assert_includes @spec.request_payload_ruby, 'build_recipient(operation, requisite, request_method)'
    assert_equal %w[sbp card], @spec.recipient_spec['methods'].keys
    assert_includes @spec.recipient_spec['methods']['sbp']['required'], 'bank_code'
    assert_includes @spec.recipient_spec['methods']['card']['required'], 'card_number'
  end

  def test_webhook
    assert_equal 4, @spec.webhook.events.size
    assert_equal 'X-NovaPay-Signature', @spec.webhook.signature_header
    assert_equal 'SHA256', @spec.webhook.signature_alg
    assert_equal 'payout_id', @spec.webhook.id_field
    assert_equal :approve, @spec.webhook.event_actions['payout.completed']
    assert_equal :reject, @spec.webhook.event_actions['payout.failed']
  end

  def test_swagger_2_is_rejected_with_clear_message
    file = Tempfile.new(['swagger', '.yaml'])
    file.write("swagger: '2.0'\ninfo: { title: Old API, version: 1.0.0 }\npaths: {}\n")
    file.rewind

    error = assert_raises(Paybridge::SpecParser::ParseError) do
      Paybridge::SpecParser.new(file.path, 'oldpay', Paybridge.load_config).parse
    end
    assert_match(/Swagger 2\.0/, error.message)
  ensure
    file.close!
  end
end
