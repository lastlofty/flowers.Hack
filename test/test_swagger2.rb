# frozen_string_literal: true

require 'minitest/autorun'
require 'fileutils'
require 'tmpdir'
require 'rbconfig'
require 'tempfile'
require_relative '../lib/paybridge'

# Вход Swagger 2.0 (OpenAPI 2): нормализуется во внутреннюю 3.x-модель и даёт
# те же артефакты. Универсальность на уровне PayCompiler.
class TestSwagger2 < Minitest::Test
  SPEC = File.expand_path('../examples/swagger2_legacypay.yaml', __dir__)

  def model = Paybridge.parse_only(spec_path: SPEC, provider: 'legacypay')

  def test_structure_normalized
    m = model
    assert_equal 'https://api.legacypay.example/v2', m[:base_url]  # host+basePath+schemes
    assert_equal 'apiKey', m.dig(:auth, :type)                     # securityDefinitions
    assert_equal 'X-Api-Key', m.dig(:auth, :header)
    roles = m[:endpoints].to_h { |e| [e[:role], "#{e[:method]} #{e[:path]}"] }
    assert_equal 'POST /payouts', roles['create']                 # body-param -> requestBody
    assert_equal 'GET /payouts/{id}', roles['status']
  end

  def test_generates_compiling_service_with_body
    gen = Paybridge.generate(spec_path: SPEC, provider: 'legacypay')
    code = gen.files['legacypay_service.rb']
    assert_includes code, 'def create_request'
    assert_includes code, 'amount:'            # тело из definitions через $ref
    assert_includes code, "currency: 'RUB'"    # enum из converted-схемы
    assert_includes code, 'def cancel_request' # cancel тоже распознан
    assert syntax_ok?(code), code
  end

  def test_verify_passes
    provider = 'legacypay2'
    dir = Dir.mktmpdir('pb_sw_')
    gen = Paybridge.generate(spec_path: SPEC, provider: provider)
    gen.files.each { |name, body| File.binwrite(File.join(dir, name), body) }
    FileUtils.cp(Paybridge::BASE_SERVICE, File.join(dir, 'base_service.rb'))
    report = Paybridge::Verifier.new(dir).run
    assert_equal 0, report.failed,
                 report.cases.select { |c| c.status == 'failed' }.map { |c| "#{c.name} #{c.detail}" }.join('; ')
    assert_operator report.passed, :>=, 3
  end

  def syntax_ok?(code)
    file = Tempfile.new(['s', '.rb'])
    file.write(code)
    file.rewind
    out = `"#{RbConfig.ruby}" -c "#{file.path}" 2>&1`
    file.close!
    out.include?('Syntax OK')
  end
end
