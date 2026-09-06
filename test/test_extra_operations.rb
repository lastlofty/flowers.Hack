# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../lib/paybridge'

# Операции вне контракта (balance/refund) не теряются — генерируются как методы
# «вне Provider::BaseService». (BivaetDS: fetch_balance.)
class TestExtraOperations < Minitest::Test
  def code(rel, provider)
    Paybridge.generate(spec_path: File.expand_path("../examples/#{rel}", __dir__), provider: provider)
             .files["#{provider}_service.rb"]
  end

  def test_balance_endpoint_becomes_fetch_balance
    # у novapay есть GET /balance
    c = code('provider_api.yaml', 'novapay')
    assert_includes c, 'def fetch_balance'
    assert_includes c, 'Вне контракта Provider::BaseService'
    assert_includes c, 'client.get("#{BASE_URL}/balance"'
  end

  def test_absent_when_no_extra_endpoint
    c = code('bluepay_api.yaml', 'bluepay')
    refute_includes c, 'def fetch_balance'
    refute_includes c, 'def refund_request'
  end

  def test_extra_operations_in_mapping
    map = Paybridge.generate(spec_path: File.expand_path('../examples/provider_api.yaml', __dir__),
                             provider: 'novapay').files['novapay_mapping.yml']
    assert_match(/name: fetch_balance/, map)
  end
end
