# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../lib/paybridge'

# Golden-file: генерация детерминирована и не дрейфует. Каждый сгенерированный
# файл должен побайтово совпадать с эталоном в test/golden/. Если изменение
# намеренное — обновить эталон командой `rake golden`.
class TestGolden < Minitest::Test
  GOLDEN = File.expand_path('golden', __dir__)

  PROVIDERS = {
    'novapay'  => 'examples/provider_api.yaml',
    'bluepay'  => 'examples/bluepay_api.yaml',
    'swiftpay' => 'examples/swiftpay_api.yaml',
    'europay'  => 'examples/europay_api.yaml'
  }.freeze

  PROVIDERS.each do |provider, spec_rel|
    define_method("test_golden_#{provider}") do
      spec_path = File.expand_path("../#{spec_rel}", __dir__)
      gen = Paybridge.generate(spec_path: spec_path, provider: provider)

      gen.files.each do |name, body|
        golden = File.join(GOLDEN, provider, name)
        assert File.exist?(golden), "нет эталона #{provider}/#{name} — запусти `rake golden`"
        assert_equal File.binread(golden), body.b,
                     "#{provider}/#{name} отличается от эталона. Если изменение намеренное — `rake golden`."
      end
    end
  end

  def test_generation_is_deterministic
    spec = File.expand_path('../examples/provider_api.yaml', __dir__)
    a = Paybridge.generate(spec_path: spec, provider: 'novapay').files
    b = Paybridge.generate(spec_path: spec, provider: 'novapay').files
    assert_equal a, b, 'генерация не детерминирована'
  end
end
