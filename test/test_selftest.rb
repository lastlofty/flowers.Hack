# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../lib/paybridge'

# `integrate selftest` запускает сгенерированный *_service_spec.rb (реальный
# артефакт) в отдельном процессе и подтверждает, что его тесты зелёные.
class TestSelftest < Minitest::Test
  def generate_into(dir, provider = 'novapay')
    capture_io do
      Paybridge::CLI.start(['--spec', File.expand_path('../examples/provider_api.yaml', __dir__),
                            '--provider', provider, '--output', dir])
    end
  end

  def run_selftest(dir)
    code = nil
    out = capture_io { code = Paybridge::CLI.start(['selftest', '--dir', dir]) }
    [code, out.join]
  end

  def test_generated_spec_passes
    Dir.mktmpdir('pb_st_') do |dir|
      generate_into(dir)
      code, out = run_selftest(dir)
      assert_equal 0, code, out
      assert_match(/0 failures, 0 errors/, out)
    end
  end

  def test_missing_spec_file_is_error
    Dir.mktmpdir('pb_st_empty_') do |dir|
      code, = run_selftest(dir)
      assert_equal 1, code
    end
  end
end
