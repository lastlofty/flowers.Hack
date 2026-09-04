# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require_relative '../lib/paybridge'

# P1 §7: отсутствующий обязательный реквизит (bank_code при sbp) даёт понятную
# ошибку ДО отправки запроса.
class TestRequisite < Minitest::Test
  def novapay_service
    dir = Dir.mktmpdir('pb_req_')
    gen = Paybridge.generate(
      spec_path: File.expand_path('../examples/provider_api.yaml', __dir__),
      provider: 'novapay'
    )
    File.write(File.join(dir, 'novapay_service.rb'), gen.files['novapay_service.rb'])
    FileUtils.cp(Paybridge::BASE_SERVICE, File.join(dir, 'base_service.rb'))
    require File.join(dir, 'base_service.rb') unless defined?(Provider::BaseService)
    require File.join(dir, 'novapay_service.rb') unless Provider.const_defined?(:NovapayService, false)
    Provider::NovapayService
  end

  def op(requisite)
    Struct.new(:amount, :id, :payout_requisite, :provider_operation_id, :idempotency_key,
               keyword_init: true).new(amount: 5000, id: 'o', payout_requisite: requisite,
                                       provider_operation_id: 'p', idempotency_key: 'i')
  end

  def svc
    @svc ||= novapay_service.new(provider: Struct.new(:credentials).new({}))
  end

  def test_missing_bank_code_is_rejected
    requisite = { 'sbp' => { 'phone' => '79001234567' } } # нет bank_code
    result = svc.check_conditions(op(requisite), 'create')
    assert result.failed?
    assert_equal 'missing_requisite', result.message
  end

  def test_full_requisite_passes
    requisite = { 'sbp' => { 'phone' => '79001234567', 'bank_code' => '044525225' } }
    result = svc.check_conditions(op(requisite), 'create')
    assert result.success?, "полные реквизиты должны проходить: #{result.message}"
  end
end
