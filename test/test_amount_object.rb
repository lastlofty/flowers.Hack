# frozen_string_literal: true

require 'minitest/autorun'
require 'tempfile'
require 'rbconfig'
require_relative '../lib/paybridge'

# Сумма как ОБЪЕКТ { value, currency } (как у ЮKassa), плюс слияние allOf.
class TestAmountObject < Minitest::Test
  SPEC = <<~YAML
    openapi: 3.0.3
    info: { title: T, version: "1.0.0" }
    servers: [ { url: https://x.example/v1 } ]
    paths:
      /payments:
        post:
          operationId: create
          security: []
          requestBody:
            required: true
            content: { application/json: { schema: { $ref: "#/components/schemas/CreatePayment" } } }
          responses:
            '200': { description: ok, content: { application/json: { schema: { type: object, properties: { id: {type: string}, status: {type: string, enum: [pending, succeeded]} } } } } }
    components:
      schemas:
        CreatePayment:
          type: object
          required: [amount]
          properties:
            amount:
              allOf:
              - $ref: "#/components/schemas/Money"
              - description: "Сумма платежа"
        Money:
          type: object
          required: [value, currency]
          properties:
            value: { type: string, example: "10.00" }
            currency: { $ref: "#/components/schemas/Cur" }
        Cur:
          type: string
          enum: [RUB, USD]
  YAML

  def code
    file = Tempfile.new(['s', '.yaml'])
    file.write(SPEC)
    file.rewind
    Paybridge.generate(spec_path: file.path, provider: 'moneypay').files['moneypay_service.rb']
  ensure
    file.close!
  end

  def test_amount_object_mapped_via_allof
    c = code
    # allOf слит -> amount распознан как объект { value, currency }
    assert_includes c, "value: format('%.2f', operation.amount)"
    assert_includes c, "currency: 'RUB'" # первое значение enum
    refute_includes c, "dig('',"          # нет вырожденной пустой группы
  end

  def test_compiles
    file = Tempfile.new(['svc', '.rb'])
    file.write(code)
    file.rewind
    out = `"#{RbConfig.ruby}" -c "#{file.path}" 2>&1`
    file.close!
    assert_includes out, 'Syntax OK'
  end
end
