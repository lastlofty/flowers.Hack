# frozen_string_literal: true

require 'minitest/autorun'
require 'yaml'
require_relative '../lib/paybridge'

# `<provider>_mapping.yml` — «что инструмент понял»: провенанс + все решения
# генератора одним читаемым/машиночитаемым файлом.
class TestMappingGenerator < Minitest::Test
  def mapping(spec, provider)
    yaml = Paybridge.generate(spec_path: spec, provider: provider).files["#{provider}_mapping.yml"]
    YAML.safe_load(yaml)
  end

  def test_clean_provider_mapping
    m = mapping(File.expand_path('../examples/provider_api.yaml', __dir__), 'novapay')
    assert_match(/\APayBridge /, m.dig('provenance', 'generator'))
    assert_equal 64, m.dig('provenance', 'spec_sha256').length # sha256 hex
    assert_equal 'POST /payouts', m.dig('recognized', 'create')
    assert_equal 'GET /payouts/{payout_id}', m.dig('recognized', 'status')
    assert_equal 'apiKey', m.dig('auth', 'type')
    assert_equal 'minor', m.dig('amount', 'unit')
    assert_equal %w[sbp card], m['recipient_methods']
    assert_equal 0, m.dig('summary', 'manual_fields')
  end

  def test_manual_fields_surface_in_mapping
    m = mapping(File.expand_path('../examples/manualpay_api.yaml', __dir__), 'manualpay')
    fields = m['manual_fields'].map { |f| f['field'] }
    assert_includes fields, 'merchant_category'
    assert_includes fields, 'statement_descriptor'
    assert(m['manual_fields'].all? { |f| f['hint'] && f['where'] })
    assert_equal 2, m.dig('summary', 'manual_fields')
  end

  def test_mapping_is_deterministic
    spec = File.expand_path('../examples/provider_api.yaml', __dir__)
    a = Paybridge.generate(spec_path: spec, provider: 'novapay').files['novapay_mapping.yml']
    b = Paybridge.generate(spec_path: spec, provider: 'novapay').files['novapay_mapping.yml']
    assert_equal a, b
  end
end
