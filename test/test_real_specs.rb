# frozen_string_literal: true

require 'minitest/autorun'
require 'tempfile'
require 'rbconfig'
require_relative '../lib/paybridge'

# Универсальность на РЕАЛЬНЫХ спеках: для каждой спеки в examples/real/ генерация
# должна давать компилирующийся сервис (ruby -c) и не крашиться. Спеки, которых
# нет локально/в CI (напр. большой Stripe качается скриптом), просто пропускаются.
class TestRealSpecs < Minitest::Test
  REAL_DIR = File.expand_path('../examples/real', __dir__)

  Dir[File.join(REAL_DIR, '*.yaml')].sort.each do |spec_path|
    provider = File.basename(spec_path, '.yaml').gsub(/[^a-z0-9_]/, '')

    define_method("test_generates_and_compiles_#{provider}") do
      gen = Paybridge.generate(spec_path: spec_path, provider: provider)
      code = gen.files["#{provider}_service.rb"]
      assert_includes code, 'module Provider'
      assert syntax_ok?(code), "#{provider}: сервис не компилируется"
    end
  end

  def test_real_dir_has_at_least_one_spec
    skip 'нет реальных спек локально (запусти examples/real/fetch.sh)' if Dir[File.join(REAL_DIR, '*.yaml')].empty?

    refute_empty Dir[File.join(REAL_DIR, '*.yaml')]
  end

  def syntax_ok?(code)
    file = Tempfile.new(['svc', '.rb'])
    file.write(code)
    file.rewind
    out = `"#{RbConfig.ruby}" -c "#{file.path}" 2>&1`
    file.close!
    out.include?('Syntax OK')
  end
end
