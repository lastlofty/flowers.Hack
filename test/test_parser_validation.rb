# frozen_string_literal: true

require 'minitest/autorun'
require 'tempfile'
require_relative '../lib/paybridge'

# P1 §9: некорректные разделы спеки -> понятная GenerationError (API -> 422).
class TestParserValidation < Minitest::Test
  def generate(yaml)
    f = Tempfile.new(['s', '.yaml'])
    f.write(yaml)
    f.rewind
    Paybridge.generate(spec_path: f.path, provider: 'testpay')
  ensure
    f.close!
  end

  def test_paths_not_object_is_generation_error
    err = assert_raises(Paybridge::GenerationError) do
      generate(<<~YAML)
        openapi: 3.0.3
        info: { title: T, version: "1.0.0" }
        paths: invalid
      YAML
    end
    assert_match(/paths/i, err.message)
  end

  def test_swagger_2_is_accepted
    # Swagger 2.0 нормализуется на входе -> валидная 2.0-спека генерируется.
    gen = generate(<<~YAML)
      swagger: "2.0"
      info: { title: T, version: "1.0.0" }
      host: api.t.example
      basePath: /v1
      schemes: [https]
      paths:
        /pay:
          post:
            operationId: create
            parameters:
              - { name: body, in: body, required: true, schema: { type: object, required: [amount], properties: { amount: { type: integer, minimum: 100 } } } }
            responses:
              '201': { description: ok, schema: { type: object, properties: { id: { type: string }, status: { type: string, enum: [pending, done] } } } }
    YAML
    assert_includes gen.files['testpay_service.rb'], 'module Provider'
  end
end
