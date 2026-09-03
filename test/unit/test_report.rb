# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../lib/paybridge/report'

class TestReport < Minitest::Test
  def setup
    @report = Paybridge::Report.new
  end

  def test_starts_empty
    refute @report.any?
    assert_empty @report.warnings
  end

  def test_warn_accumulates_in_order
    @report.warn('первое')
    @report.warn('второе')
    assert @report.any?
    assert_equal ['первое', 'второе'], @report.warnings
  end

  def test_warn_returns_self_for_chaining
    assert_same @report, @report.warn('x')
  end

  def test_each_yields_every_warning
    @report.warn('a').warn('b')
    collected = []
    @report.each { |w| collected << w }
    assert_equal %w[a b], collected
  end
end
