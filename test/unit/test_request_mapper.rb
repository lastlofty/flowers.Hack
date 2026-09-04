# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../lib/paybridge/report'
require_relative '../../lib/paybridge/mappers/request_mapper'

class TestRequestMapper < Minitest::Test
  # Изолированная схема запроса: сумма в копейках + вложенный recipient,
  # где поля условно принадлежат разным type (sbp/card).
  SCHEMA = {
    'required' => %w[amount external_id recipient],
    'properties' => {
      'amount' => { 'type' => 'integer', 'description' => 'Сумма в копейках', 'minimum' => 100_000 },
      'currency' => { 'type' => 'string', 'enum' => ['RUB'] },
      'external_id' => { 'type' => 'string' },
      'recipient' => {
        'type' => 'object',
        'required' => %w[type phone],
        'properties' => {
          'type' => { 'type' => 'string', 'enum' => %w[sbp card] },
          'phone' => { 'type' => 'string' },
          'bank_code' => { 'type' => 'string', 'description' => 'обязателен для type=sbp' },
          'card_number' => { 'type' => 'string', 'description' => 'обязателен для type=card' }
        }
      }
    }
  }.freeze

  def build(overrides = {})
    @report = Paybridge::Report.new
    Paybridge::Mappers::RequestMapper.new(@report, overrides).build(SCHEMA)
  end

  def test_amount_detected_as_minor_by_default
    result = build
    assert result.amount[:minor_units]
    assert_equal 100_000, result.amount[:min_native]
    assert_includes result.ruby, '(operation.amount * 100).to_i'
  end

  def test_currency_and_external_id
    result = build
    assert_equal 'RUB', result.currency
    assert_equal 'external_id', result.external_id_field
    assert_includes result.ruby, "currency: 'RUB'"
    assert_includes result.ruby, 'operation.id.to_s'
  end

  def test_nested_requisite_filtered_by_type
    result = build
    assert_includes result.ruby, "type: 'sbp'"
    assert_includes result.ruby, "requisite.dig('sbp', 'phone')"
    assert_includes result.ruby, "requisite.dig('sbp', 'bank_code')"
    refute_includes result.ruby, 'card_number'
  end

  def test_optional_fields_get_compact
    assert_includes build.ruby, '.compact'
  end

  def test_amount_unit_override_major_disables_conversion
    result = build('amount_unit' => 'major')
    refute result.amount[:minor_units]
    refute_includes result.ruby, '(operation.amount * 100)'
    assert_includes result.ruby, 'amount: operation.amount'
  end

  def test_guessing_amount_and_required_if_warns
    build
    joined = @report.warnings.join("\n")
    assert_includes joined, 'Единица суммы'
    assert_includes joined, 'Условная обязательность'
  end

  def test_required_if_override_suppresses_guess_warning
    build('required_if' => { 'bank_code' => 'sbp', 'card_number' => 'card' })
    refute_includes @report.warnings.join("\n"), 'Условная обязательность'
  end

  def test_empty_schema_is_empty_hash_literal
    @report = Paybridge::Report.new
    result = Paybridge::Mappers::RequestMapper.new(@report, {}).build(nil)
    assert_match(/\A\{\s*\}\z/, result.ruby)
  end
end
