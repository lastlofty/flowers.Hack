# frozen_string_literal: true

require 'minitest/autorun'
require 'tempfile'
require_relative '../lib/paybridge'

# overrides для выбора эндпоинтов и auth-схемы — ручное управление там, где
# эвристика неизбежно неоднозначна (крупные спеки, несколько security-схем).
class TestSelectionOverrides < Minitest::Test
  SPEC = <<~YAML
    openapi: 3.0.3
    info: { title: T, version: "1.0.0" }
    servers: [ { url: https://x.example/v1 } ]
    security: [ { Bearer: [] } ]
    paths:
      /sessions:
        post:
          operationId: createSession
          requestBody: { required: true, content: { application/json: { schema: { type: object, properties: { a: {type: string} } } } } }
          responses: { '200': { description: ok, content: { application/json: { schema: { type: object, properties: { id: {type: string} } } } } } }
      /payments:
        post:
          operationId: createPayment
          requestBody: { required: true, content: { application/json: { schema: { type: object, required: [amount], properties: { amount: {type: integer, minimum: 100} } } } } }
          responses: { '201': { description: ok, content: { application/json: { schema: { type: object, properties: { id: {type: string}, status: {type: string, enum: [pending, done]} } } } } } }
      /payments/{id}:
        get:
          operationId: getPayment
          parameters: [ { name: id, in: path, required: true, schema: { type: string } } ]
          responses: { '200': { description: ok, content: { application/json: { schema: { type: object, properties: { id: {type: string}, status: {type: string, enum: [pending, done]} } } } } } }
    components:
      securitySchemes:
        Bearer: { type: http, scheme: bearer }
        Key: { type: apiKey, in: header, name: X-Api-Key }
  YAML

  def parse(overrides)
    file = Tempfile.new(['s', '.yaml'])
    file.write(SPEC)
    file.rewind
    Paybridge::SpecParser.new(file.path, 'ovpay', Paybridge.load_config(Paybridge::DEFAULT_CONFIG), overrides).parse
  ensure
    file.close!
  end

  def test_force_create_endpoint
    # без override /payments и /sessions обе платёжны? /sessions штрафуется -> /payments.
    forced = parse('create_endpoint' => 'POST /sessions')
    assert_equal '/sessions', forced.create_endpoint.path
  end

  def test_force_security_scheme
    default = parse({})
    forced = parse('security_scheme' => 'Key')
    assert_equal 'http', default.auth.scheme_type
    assert_equal 'apiKey', forced.auth.scheme_type
    assert_equal 'X-Api-Key', forced.auth.header_name
  end

  def test_unknown_override_falls_back_with_warning
    spec = parse('create_endpoint' => 'POST /does-not-exist')
    refute_nil spec.create_endpoint # эвристика сработала
    assert(spec.report.warnings.any? { |w| w.include?('create_endpoint') })
  end
end
