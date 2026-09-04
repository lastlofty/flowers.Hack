# frozen_string_literal: true

require 'minitest/autorun'
require 'fileutils'
require 'tmpdir'
require_relative '../lib/paybridge'

# Прогон fixtures против сгенерированного сервиса: генерируем интеграцию в temp,
# кладём base_service рядом и проверяем, что все сценарии проходят.
class TestVerifier < Minitest::Test
  def verify(spec_file, provider)
    dir = Dir.mktmpdir("pb_#{provider}_")
    gen = Paybridge.generate(
      spec_path: File.expand_path("../examples/#{spec_file}", __dir__),
      provider: provider
    )
    gen.files.each { |name, body| File.write(File.join(dir, name), body) }
    FileUtils.cp(Paybridge::BASE_SERVICE, File.join(dir, 'base_service.rb'))
    Paybridge::Verifier.new(dir).run
  end

  def test_novapay_scenarios_pass
    report = verify('provider_api.yaml', 'novapay')
    refute_empty report.cases
    assert report.all_passed?,
           "провал: #{report.cases.reject(&:ok).map { |c| "#{c.name} #{c.detail}" }.join('; ')}"
  end

  def test_bluepay_scenarios_pass
    report = verify('bluepay_api.yaml', 'bluepay')
    refute_empty report.cases
    assert report.all_passed?,
           "провал: #{report.cases.reject(&:ok).map { |c| "#{c.name} #{c.detail}" }.join('; ')}"
  end

  def test_europay_scenarios_pass
    report = verify('europay_api.yaml', 'europay')
    refute_empty report.cases
    assert report.all_passed?,
           "провал: #{report.cases.reject(&:ok).map { |c| "#{c.name} #{c.detail}" }.join('; ')}"
  end

  def test_report_counts
    report = verify('provider_api.yaml', 'novapay')
    assert_equal report.cases.size, report.passed + report.failed
  end

  def test_checks_conditions_and_invalid_signature
    report = verify('provider_api.yaml', 'novapay')
    names = report.cases.map(&:name)

    assert_includes names, 'check_conditions.normal'
    assert_includes names, 'callback.invalid_signature'
    assert report.cases.find { |test_case| test_case.name == 'callback.invalid_signature' }.ok
  end
end
