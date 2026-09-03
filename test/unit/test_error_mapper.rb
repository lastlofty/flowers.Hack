# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../lib/paybridge/report'
require_relative '../../lib/paybridge/mappers/error_mapper'

class TestErrorMapper < Minitest::Test
  def setup
    @report = Paybridge::Report.new
    @config = {
      'error_map' => {
        '402' => { 'code' => 'insufficient_balance', 'action' => 'retry later' },
        '500' => { 'code' => 'internal_error' }
      },
      'http_symbol' => { '402' => 'payment_required' }
    }
    @mapper = Paybridge::Mappers::ErrorMapper.new(@config, @report)
  end

  def test_maps_known_codes_to_code_and_symbol
    error, symbol = @mapper.build([402])
    assert_equal 'insufficient_balance', error[402]
    assert_equal 'payment_required', symbol[402]
  end

  def test_missing_symbol_falls_back_to_internal
    _error, symbol = @mapper.build([500])
    assert_equal 'internal_server_error', symbol[500]
  end

  def test_ignores_success_codes
    error, = @mapper.build([200, 201, 402])
    refute error.key?(200)
    refute error.key?(201)
    assert error.key?(402)
  end

  def test_unknown_code_warns_and_defaults
    error, symbol = @mapper.build([418])
    assert_equal 'internal_error', error[418]
    assert_equal 'internal_server_error', symbol[418]
    assert @report.any?
  end

  def test_sorted_by_code
    error, = @mapper.build([500, 402])
    assert_equal [402, 500], error.keys
  end

  def test_action_for
    assert_equal 'retry later', @mapper.action_for(402)
    assert_nil @mapper.action_for(500)
  end
end
