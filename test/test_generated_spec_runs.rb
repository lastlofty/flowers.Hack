# frozen_string_literal: true

require 'minitest/autorun'
require 'fileutils'
require 'tmpdir'
require 'rbconfig'
require_relative '../lib/paybridge'

# Сгенерированный <provider>_service_spec.rb должен реально ЗАПУСКАТЬСЯ и проходить.
# Генерируем интеграцию в temp, кладём base_service рядом и запускаем spec как
# отдельный ruby-процесс (как это сделает интеграционный репозиторий).
class TestGeneratedSpecRuns < Minitest::Test
  def run_generated_spec(spec_file, provider)
    dir = Dir.mktmpdir("pb_spec_#{provider}_")
    gen = Paybridge.generate(
      spec_path: File.expand_path("../examples/#{spec_file}", __dir__),
      provider: provider
    )
    gen.files.each { |name, body| File.write(File.join(dir, name), body) }
    FileUtils.cp(Paybridge::BASE_SERVICE, File.join(dir, 'base_service.rb'))

    spec_path = File.join(dir, "#{provider}_service_spec.rb")
    output = `"#{RbConfig.ruby}" "#{spec_path}" 2>&1`
    [$?, output]
  end

  def assert_spec_passes(spec_file, provider)
    status, output = run_generated_spec(spec_file, provider)
    assert status.success?, "сгенерированный spec упал:\n#{output}"
    assert_match(/0 failures, 0 errors/, output, output)
  end

  def test_novapay_generated_spec
    assert_spec_passes('provider_api.yaml', 'novapay')
  end

  def test_bluepay_generated_spec
    assert_spec_passes('bluepay_api.yaml', 'bluepay')
  end

  def test_swiftpay_generated_spec
    assert_spec_passes('swiftpay_api.yaml', 'swiftpay')
  end
end
