# frozen_string_literal: true

require 'minitest/autorun'
require 'tempfile'
require_relative '../lib/paybridge'

# На больших спеках POST-методов много: create-эндпоинт выбирается ранжированием
# по «платёжности», а не «первым попавшимся» (регрессия Adyen: /applePay/sessions).
class TestEndpointSelection < Minitest::Test
  SPEC = <<~YAML
    openapi: 3.0.3
    info: { title: T, version: "1.0.0" }
    servers: [ { url: https://x.example/v1 } ]
    paths:
      /applePay/sessions:
        post:
          operationId: createApplePaySession
          security: []
          requestBody: { required: true, content: { application/json: { schema: { type: object, properties: { displayName: {type: string} } } } } }
          responses: { '200': { description: ok, content: { application/json: { schema: { type: object, properties: { id: {type: string} } } } } } }
      /paymentMethods:
        post:
          operationId: listPaymentMethods
          security: []
          requestBody: { required: true, content: { application/json: { schema: { type: object, properties: { merchantId: {type: string} } } } } }
          responses: { '200': { description: ok } }
      /payments:
        post:
          operationId: createPayment
          security: []
          requestBody: { required: true, content: { application/json: { schema: { type: object, required: [amount], properties: { amount: {type: integer, minimum: 100} } } } } }
          responses: { '201': { description: ok, content: { application/json: { schema: { type: object, properties: { id: {type: string}, status: {type: string, enum: [pending, done]} } } } } } }
      /payments/{id}:
        get:
          operationId: getPayment
          security: []
          parameters: [ { name: id, in: path, required: true, schema: { type: string } } ]
          responses: { '200': { description: ok, content: { application/json: { schema: { type: object, properties: { id: {type: string}, status: {type: string, enum: [pending, done]} } } } } } }
      /paymentLinks/{linkId}:
        get:
          operationId: getPaymentLink
          security: []
          parameters: [ { name: linkId, in: path, required: true, schema: { type: string } } ]
          responses: { '200': { description: ok } }
    components: {}
  YAML

  def spec
    file = Tempfile.new(['s', '.yaml'])
    file.write(SPEC)
    file.rewind
    Paybridge::SpecParser.new(file.path, 'rankpay', Paybridge.load_config(Paybridge::DEFAULT_CONFIG)).parse
  ensure
    file.close!
  end

  def test_create_prefers_payment_endpoint_over_first_post
    s = spec
    assert_equal '/payments', s.create_endpoint.path,
                 'create должен выбираться по платёжности, а не как первый POST'
  end

  def test_status_prefers_same_resource_as_create
    s = spec
    assert_equal '/payments/{id}', s.status_endpoint.path,
                 'status должен быть GET {id} на ресурсе создания (/payments)'
  end
end
