# frozen_string_literal: true

require 'minitest/autorun'
require 'tempfile'
require 'tmpdir'
require 'fileutils'
require_relative '../lib/paybridge'

# OAuth2 / OpenID Connect: access-токен передаётся как Bearer (получение токена —
# вне генерации). Паритет с конкурентами по auth-схемам.
class TestOAuth2 < Minitest::Test
  SPEC = <<~YAML
    openapi: 3.0.3
    info: { title: OAuthPay, version: "1.0.0" }
    servers: [ { url: https://api.oauthpay.example/v1 } ]
    security: [ { OAuth: [] } ]
    paths:
      /payments:
        post:
          operationId: create
          requestBody: { required: true, content: { application/json: { schema: { type: object, required: [amount], properties: { amount: { type: integer, minimum: 100 } } } } } }
          responses: { '201': { description: ok, content: { application/json: { schema: { type: object, properties: { id: {type: string}, status: {type: string, enum: [pending, done]} } } } } } }
      /payments/{id}:
        get:
          operationId: get
          parameters: [ { name: id, in: path, required: true, schema: { type: string } } ]
          responses: { '200': { description: ok, content: { application/json: { schema: { type: object, properties: { id: {type: string}, status: {type: string, enum: [pending, done]} } } } } } }
    components:
      securitySchemes:
        OAuth:
          type: oauth2
          flows: { clientCredentials: { tokenUrl: https://api.oauthpay.example/token, scopes: {} } }
  YAML

  def gen
    f = Tempfile.new(['o', '.yaml'])
    f.write(SPEC)
    f.rewind
    Paybridge.generate(spec_path: f.path, provider: 'oauthpay')
  ensure
    f.close!
  end

  def test_oauth2_generates_bearer_auth
    code = gen.files['oauthpay_service.rb']
    assert_includes code, %(Bearer \#{provider.credentials.fetch('token')})
  end

  def test_oauth2_verifies
    dir = Dir.mktmpdir('pb_oauth_')
    g = gen
    g.files.each { |name, body| File.binwrite(File.join(dir, name), body) }
    FileUtils.cp(Paybridge::BASE_SERVICE, File.join(dir, 'base_service.rb'))
    report = Paybridge::Verifier.new(dir).run
    assert_equal 0, report.failed,
                 report.cases.select { |c| c.status == 'failed' }.map { |c| "#{c.name} #{c.detail}" }.join('; ')
  end
end
