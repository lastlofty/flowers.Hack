# frozen_string_literal: true

require 'minitest/autorun'
require 'json'
require_relative '../lib/paybridge'

# generation.json — машиночитаемый вердикт о допуске (admission-gate для CI).
class TestVerdictGenerator < Minitest::Test
  def verdict(rel, provider)
    JSON.parse(Paybridge.generate(spec_path: File.expand_path("../examples/#{rel}", __dir__), provider: provider)
                        .files['generation.json'])
  end

  def test_clean_provider_admitted
    v = verdict('provider_api.yaml', 'novapay')
    assert_equal true, v['admitted']
    assert_equal 'ready', v['verdict']
    assert_empty v['blockers']
    assert_equal 0, v.dig('diagnostics', 'error')
  end

  def test_manual_fields_block_admission
    v = verdict('manualpay_api.yaml', 'manualpay')
    assert_equal false, v['admitted']
    assert_equal 2, v['manual_fields']
    assert(v['blockers'].any? { |b| b.include?('ручного заполнения') })
  end

  def test_empty_blockers_deterministic
    raw = Paybridge.generate(spec_path: File.expand_path('../examples/provider_api.yaml', __dir__),
                             provider: 'novapay').files['generation.json']
    assert_includes raw, '"blockers": []' # нормализованный пустой массив, не "[\n]"
  end
end
