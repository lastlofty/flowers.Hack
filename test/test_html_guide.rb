# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../lib/paybridge'

# `<provider>_integration.html` — портируемая HTML-инструкция (CLI: integrate docs).
class TestHtmlGuide < Minitest::Test
  def spec_for(rel, provider)
    Paybridge::SpecParser.new(
      File.expand_path("../examples/#{rel}", __dir__), provider,
      Paybridge.load_config(Paybridge::DEFAULT_CONFIG)
    ).parse
  end

  def html(rel, provider)
    Paybridge::Generators::HtmlGuideGenerator.new(spec_for(rel, provider)).render
  end

  def test_contains_core_sections
    h = html('provider_api.yaml', 'novapay')
    assert_includes h, '<!doctype html>'
    assert_includes h, 'Авторизация'
    assert_includes h, 'Методы'
    assert_includes h, 'POST /payouts'
    assert_includes h, 'sha256'
  end

  def test_manual_and_diagnostics_render
    h = html('manualpay_api.yaml', 'manualpay')
    assert_includes h, 'Заполните вручную'
    assert_includes h, 'merchant_category'
    assert_includes h, 'Диагностика'
  end

  def test_html_is_escaped
    # значения из спеки экранируются (нет «сырых» угловых скобок из данных)
    h = html('provider_api.yaml', 'novapay')
    refute_match(/<script/i, h)
  end

  def test_docs_command_writes_file
    Dir.mktmpdir('pb_docs_') do |dir|
      code = nil
      capture_io do
        code = Paybridge::CLI.start(['docs', '--spec',
                                     File.expand_path('../examples/provider_api.yaml', __dir__),
                                     '--provider', 'novapay', '--output', dir])
      end
      assert_equal 0, code
      assert File.file?(File.join(dir, 'novapay_integration.html'))
    end
  end
end
