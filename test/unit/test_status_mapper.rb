# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../lib/paybridge/report'
require_relative '../../lib/paybridge/mappers/status_mapper'

class TestStatusMapper < Minitest::Test
  def setup
    @report = Paybridge::Report.new
    @config = {
      'status_map' => { 'pending' => 'in_progress', 'completed' => 'approved' },
      'unknown_status_default' => 'in_progress'
    }
    @mapper = Paybridge::Mappers::StatusMapper.new(@config, @report)
  end

  def test_maps_known_statuses
    result = @mapper.build(%w[pending completed])
    assert_equal({ 'pending' => 'in_progress', 'completed' => 'approved' }, result)
    refute @report.any?
  end

  def test_lookup_is_case_insensitive
    result = @mapper.build(%w[PENDING])
    assert_equal 'in_progress', result['PENDING']
  end

  def test_unknown_status_falls_back_to_default_and_warns
    result = @mapper.build(%w[frozen])
    assert_equal 'in_progress', result['frozen']
    assert @report.any?
    assert_match(/frozen/, @report.warnings.first)
  end

  def test_preserves_input_order
    result = @mapper.build(%w[completed pending])
    assert_equal %w[completed pending], result.keys
  end

  def test_empty_enum_gives_empty_map
    assert_empty @mapper.build([])
  end
end
