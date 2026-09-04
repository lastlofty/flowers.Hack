# frozen_string_literal: true

require 'minitest/autorun'
require 'tempfile'
require 'tmpdir'
require 'fileutils'
require_relative '../lib/paybridge'

# P1 §7: минимум суммы без потери копеек (150 центов -> 1.50), валидация overrides.
class TestAmounts < Minitest::Test
  SPEC = <<~YAML
    openapi: 3.0.3
    info: { title: T, version: "1.0.0" }
    servers: [ { url: https://x.example/v1 } ]
    paths:
      /pay:
        post:
          operationId: create
          security: []
          requestBody:
            required: true
            content: { application/json: { schema: { type: object, required: [amount], properties: { amount: { type: integer, description: "Сумма в центах", minimum: 150 } } } } }
          responses:
            '201': { description: ok, content: { application/json: { schema: { type: object, properties: { id: {type: string}, status: {type: string, enum: [pending, completed]} } } } } }
    components: {}
  YAML

  def load_service
    dir = Dir.mktmpdir('pb_amt_')
    file = Tempfile.new(['s', '.yaml'])
    file.write(SPEC)
    file.rewind
    gen = Paybridge.generate(spec_path: file.path, provider: 'centpay')
    File.write(File.join(dir, 'centpay_service.rb'), gen.files['centpay_service.rb'])
    FileUtils.cp(Paybridge::BASE_SERVICE, File.join(dir, 'base_service.rb'))
    require File.join(dir, 'base_service.rb') unless defined?(Provider::BaseService)
    require File.join(dir, 'centpay_service.rb') unless Provider.const_defined?(:CentpayService, false)
    Provider::CentpayService
  ensure
    file.close!
  end

  def op(amount)
    Struct.new(:amount, :id, :payout_requisite, :provider_operation_id, :idempotency_key,
               keyword_init: true).new(amount: amount, id: 'o', payout_requisite: {},
                                       provider_operation_id: 'p', idempotency_key: 'i')
  end

  def svc
    @svc ||= load_service.new(provider: Struct.new(:credentials).new({}))
  end

  def test_amount_1_00_rejected_at_min_150_cents
    result = svc.check_conditions(op(1.00), 'create')
    assert result.failed?
    assert_equal 'amount_too_low', result.message
  end

  def test_amount_1_50_accepted_at_min_150_cents
    result = svc.check_conditions(op(1.50), 'create')
    assert result.success?, "1.50 должно приниматься: #{result.message}"
  end

  def test_min_stored_in_native_units
    file = Tempfile.new(['s', '.yaml'])
    file.write(SPEC)
    file.rewind
    spec = Paybridge::SpecParser.new(file.path, 'centpay', Paybridge.load_config).parse
    assert spec.amount[:minor_units]
    assert_equal 150, spec.amount[:min_native]
  ensure
    file.close!
  end

  def test_overrides_typo_rejected
    file = Tempfile.new(['s', '.yaml'])
    file.write(SPEC)
    file.rewind
    ovr = Tempfile.new(['o', '.yml'])
    ovr.write("amount_unit: minr\n")
    ovr.rewind
    err = assert_raises(Paybridge::GenerationError) do
      Paybridge.generate(spec_path: file.path, provider: 'centpay', overrides_path: ovr.path)
    end
    assert_match(/amount_unit/, err.message)
  ensure
    file.close!
    ovr.close!
  end
end
