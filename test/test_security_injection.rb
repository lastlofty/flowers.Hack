# frozen_string_literal: true

require 'minitest/autorun'
require 'tempfile'
require 'tmpdir'
require 'fileutils'
require 'rbconfig'
require_relative '../lib/paybridge'

# P0: спецификация — недоверенный ввод. Никакая её строка не должна исполняться
# как Ruby при генерации/загрузке сервиса.
class TestSecurityInjection < Minitest::Test
  def spec_yaml(title: 'T', base_url: 'https://x.example/v1', extra_property: 'zzz: { type: string }')
    <<~YAML
      openapi: 3.0.3
      info: { title: #{title.inspect}, version: "1.0.0" }
      servers: [ { url: #{base_url.inspect} } ]
      paths:
        /pay:
          post:
            operationId: create
            security: [ { Auth: [] } ]
            requestBody:
              required: true
              content:
                application/json:
                  schema:
                    type: object
                    required: [amount]
                    properties:
                      amount: { type: integer, minimum: 100 }
                      #{extra_property}
            responses:
              '201':
                description: ok
                content:
                  application/json:
                    schema:
                      type: object
                      properties:
                        id: { type: string }
                        status: { type: string, enum: [pending, completed] }
      components:
        securitySchemes:
          Auth: { type: apiKey, in: header, name: X-Api-Key }
    YAML
  end

  def generate_to_dir(**opts)
    dir = Dir.mktmpdir('pb_sec_')
    file = Tempfile.new(['spec', '.yaml'])
    file.write(spec_yaml(**opts))
    file.rewind
    gen = Paybridge.generate(spec_path: file.path, provider: 'evilprov')
    File.write(File.join(dir, 'evilprov_service.rb'), gen.files['evilprov_service.rb'])
    FileUtils.cp(Paybridge::BASE_SERVICE, File.join(dir, 'base_service.rb'))
    [dir, gen]
  ensure
    file.close!
  end

  # Заголовок с переносами строк и «полезной нагрузкой»: если бы он вырвался из
  # комментария, определилась бы константа PAYLOAD_EXECUTED. Проверяем в подпроцессе.
  def test_malicious_title_is_not_executed
    dir, = generate_to_dir(title: "Evil\nPAYLOAD_EXECUTED = 1\n#")
    base = File.join(dir, 'base_service.rb')
    svc  = File.join(dir, 'evilprov_service.rb')
    code = "require #{base.inspect}; require #{svc.inspect}; " \
           'exit(defined?(PAYLOAD_EXECUTED) ? 1 : 0)'
    system(RbConfig.ruby, '-e', code)
    assert $?.success?, 'внедрённый Ruby из info.title исполнился'
  end

  def test_quotes_and_interpolation_in_base_url_are_inert
    _dir, gen = generate_to_dir(base_url: %q{https://x'; PAYLOAD=1 #})
    code = gen.files['evilprov_service.rb']
    assert syntax_ok?(code), code
    refute_match(/^\s*PAYLOAD=1/, code)
  end

  def test_custom_field_key_does_not_break_syntax
    file = Tempfile.new(['spec', '.yaml'])
    file.write(spec_yaml(extra_property: '"custom-field": { type: string }'))
    file.rewind
    gen = Paybridge.generate(spec_path: file.path, provider: 'evilprov')
    code = gen.files['evilprov_service.rb']
    assert syntax_ok?(code), code
    assert_includes code, "'custom-field' =>"
  ensure
    file.close!
  end

  def test_invalid_provider_rejected_by_facade
    file = Tempfile.new(['spec', '.yaml'])
    file.write(spec_yaml)
    file.rewind
    err = assert_raises(Paybridge::GenerationError) do
      Paybridge.generate(spec_path: file.path, provider: 'Evil Prov!')
    end
    assert_match(/provider|провайдер/i, err.message)
  ensure
    file.close!
  end

  def syntax_ok?(code)
    f = Tempfile.new(['svc', '.rb'])
    f.write(code)
    f.rewind
    out = `"#{RbConfig.ruby}" -c "#{f.path}" 2>&1`
    f.close!
    out.include?('Syntax OK')
  end
end
