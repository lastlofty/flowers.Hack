# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../lib/paybridge'

# Объяснимость выводов: уверенность (0..1) + evidence (цитата из спеки) в коде,
# mapping.yml и HTML — «почему принято именно это и насколько уверенно».
class TestEvidence < Minitest::Test
  def gen(rel, provider)
    Paybridge.generate(spec_path: File.expand_path("../examples/#{rel}", __dir__), provider: provider)
  end

  def test_amount_unit_evidence_in_code
    code = gen('provider_api.yaml', 'novapay').files['novapay_service.rb']
    # комментарий-evidence над строкой суммы, с уверенностью
    assert_match(/# Evidence \(единица суммы, confidence 0\.\d+\):/, code)
    assert_includes code, 'amount: amount_in_minor_units(operation.amount)'
  end

  def test_confidence_and_evidence_in_diagnostics
    diags = gen('provider_api.yaml', 'novapay').warnings # плоские тексты остаются
    assert(diags.any? { |m| m.include?('Единица суммы') })
    # структурная форма — в mapping.yml/ir.json (проверяется в test_mapping_generator)
  end

  def test_high_confidence_for_explicit_description
    # 'копей' в description -> высокая уверенность 0.8 (явный сигнал)
    code = gen('provider_api.yaml', 'novapay').files['novapay_service.rb']
    assert_includes code, 'confidence 0.8'
  end
end
