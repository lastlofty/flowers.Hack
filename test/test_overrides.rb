# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../lib/paybridge'

# Overrides-механизм: то, что нельзя достать из структуры OpenAPI
# (единица суммы, кодировка подписи, условная обязательность), задаётся
# файлом-уточнением, а при его отсутствии — помечается предупреждением.
class TestOverrides < Minitest::Test
  def parse(overrides)
    path = File.expand_path('../examples/provider_api.yaml', __dir__)
    Paybridge::SpecParser.new(path, 'novapay', Paybridge.load_config, overrides).parse
  end

  def test_amount_unit_major_disables_conversion
    spec = parse('amount_unit' => 'major')
    refute spec.amount[:minor_units]
    refute_includes spec.request_payload_ruby, '(operation.amount * 100)'
    assert_includes spec.request_payload_ruby, 'operation.amount'
  end

  def test_signature_encoding_base64_changes_generated_code
    spec = parse('signature_encoding' => 'base64')
    assert_equal 'base64', spec.webhook.signature_encoding
    code = Paybridge::Generators::ServiceGenerator.new(spec, config: Paybridge.load_config).render
    assert_includes code, 'Base64.strict_encode64'
    assert_includes code, "require 'base64'"
  end

  def test_overrides_suppress_assumption_warnings
    spec = parse(
      'amount_unit' => 'minor',
      'signature_encoding' => 'hex',
      'required_if' => { 'bank_code' => 'sbp', 'card_number' => 'card' }
    )
    joined = spec.report.warnings.join("\n")
    refute_includes joined, 'Единица суммы'
    refute_includes joined, 'Кодировка подписи'
    refute_includes joined, 'Условная обязательность'
  end

  def test_missing_overrides_produce_warnings
    spec = parse({})
    joined = spec.report.warnings.join("\n")
    assert_includes joined, 'Единица суммы'
    assert_includes joined, 'Кодировка подписи'
  end

  def test_required_if_override_matches_description_result
    # overrides дают тот же результат, что и разбор description, но без догадки
    spec = parse('required_if' => { 'bank_code' => 'sbp', 'card_number' => 'card' })
    assert_includes spec.request_payload_ruby, "requisite.dig('sbp', 'bank_code')"
    refute_includes spec.request_payload_ruby, 'card_number'
  end
end
