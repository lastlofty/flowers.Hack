# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../lib/paybridge'

# SAFETY.md — аудит платёжных рисков сгенерированной интеграции.
class TestSafetyGenerator < Minitest::Test
  def safety(rel, provider)
    Paybridge.generate(spec_path: File.expand_path("../examples/#{rel}", __dir__), provider: provider)
             .files['SAFETY.md']
  end

  def test_clean_provider_audit
    md = safety('provider_api.yaml', 'novapay')
    assert_includes md, 'Аудит безопасности — novapay'
    assert_includes md, 'HMAC-SHA256'          # подпись webhook описана
    assert_includes md, 'Идемпотентность'
    assert_includes md, 'spec sha256'          # провенанс
  end

  def test_missing_signature_is_critical
    md = safety('manualpay_api.yaml', 'manualpay')
    assert_includes md, 'НЕ готово'            # вердикт: критический риск
    assert_includes md, 'спека НЕ описывает подпись'
    # поля для ручного заполнения перечислены со строкой спеки
    assert_includes md, 'merchant_category'
    assert_match(/строка \d+/, md)
  end
end
