# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../lib/paybridge'

# `integrate diff` — проверка детерминизма в CI: перегенерация должна совпадать
# с уже сгенерированным каталогом байт-в-байт.
class TestDiffCommand < Minitest::Test
  SPEC = File.expand_path('../examples/provider_api.yaml', __dir__)

  def with_generated
    Dir.mktmpdir('pb_diff_') do |dir|
      capture_io do
        Paybridge::CLI.start(['--spec', SPEC, '--provider', 'novapay', '--output', dir])
      end
      yield dir
    end
  end

  def diff_code(dir)
    code = nil
    capture_io { code = Paybridge::CLI.start(['diff', '--spec', SPEC, '--provider', 'novapay', '--dir', dir]) }
    code
  end

  def test_diff_zero_on_fresh_generation
    with_generated { |dir| assert_equal 0, diff_code(dir), 'свежая генерация должна совпадать' }
  end

  def test_diff_nonzero_on_drift
    with_generated do |dir|
      File.write(File.join(dir, 'novapay_service.rb'), 'tampered', mode: 'ab')
      assert_equal 1, diff_code(dir), 'изменённый файл должен давать ненулевой код'
    end
  end

  def test_diff_nonzero_on_missing_file
    with_generated do |dir|
      File.delete(File.join(dir, 'novapay_mapping.yml'))
      assert_equal 1, diff_code(dir), 'отсутствующий артефакт должен давать ненулевой код'
    end
  end
end
