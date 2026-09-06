# frozen_string_literal: true

require 'minitest/autorun'
require 'English'
require 'tempfile'
require 'rbconfig'
require 'tmpdir'
require 'fileutils'
require_relative '../lib/paybridge'

# Закрытие дыр из разбора: apiKey в query-параметре и http basic.
class TestAuthVariants < Minitest::Test
  def spec_yaml(security_schemes)
    <<~YAML
      openapi: 3.0.3
      info: { title: T, version: 1.0.0 }
      servers: [ { url: https://x.example/v1 } ]
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
                    required: [amount, currency]
                    properties:
                      amount: { type: integer, minimum: 100 }
                      currency: { type: string, enum: [USD] }
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
          #{security_schemes}
    YAML
  end

  def generate(security_schemes, provider)
    file = Tempfile.new(['spec', '.yaml'])
    file.write(spec_yaml(security_schemes))
    file.rewind
    Paybridge.generate(spec_path: file.path, provider: provider)
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

  def test_api_key_in_query
    gen = generate('Auth: { type: apiKey, in: query, name: api_key }', 'querypay')
    code = gen.files['querypay_service.rb']
    assert_includes code, '/pay?#{CGI.escape(\'api_key\')}=#{CGI.escape(provider.credentials.fetch(\'api_key\'))}'
    assert_includes code, "require 'cgi'"
    assert_includes code, '{} # ключ передаётся в query'
    assert syntax_ok?(code), 'сервис с query-auth не компилируется'
  end

  def test_http_basic
    gen = generate('Auth: { type: http, scheme: basic }', 'basicpay')
    code = gen.files['basicpay_service.rb']
    assert_includes code, 'Base64.strict_encode64'
    assert_includes code, "'Authorization' => \"Basic"
    assert_includes code, "require 'base64'"
    assert syntax_ok?(code), 'сервис с basic-auth не компилируется'

    fixtures = JSON.parse(gen.files['fixtures.json'])
    assert_equal 'basic', fixtures.dig('auth', 'scheme')
    assert_generated_spec_passes(gen, 'basicpay')
  end

  def assert_generated_spec_passes(gen, provider)
    output = nil
    status = nil
    Dir.mktmpdir("pb_#{provider}_") do |dir|
      gen.files.each { |name, body| File.write(File.join(dir, name), body) }
      FileUtils.cp(Paybridge::BASE_SERVICE, File.join(dir, 'base_service.rb'))
      output = `"#{RbConfig.ruby}" "#{File.join(dir, "#{provider}_service_spec.rb")}" 2>&1`
      status = $CHILD_STATUS
    end
    assert status.success?, "сгенерированный Basic Auth spec упал:\n#{output}"
    assert_match(/0 failures, 0 errors/, output)
  end
end
