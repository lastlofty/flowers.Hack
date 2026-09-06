# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../lib/paybridge/report'

class TestReport < Minitest::Test
  def test_levels_and_derived_warnings
    r = Paybridge::Report.new
    r.warn('info msg', level: :info)
    r.warn('warn msg') # default :warn
    r.warn('error msg', level: :error)

    assert_equal ['info msg', 'warn msg', 'error msg'], r.warnings # плоский вид сохранён
    by = r.diagnostics_by_level
    assert_equal ['info msg'], by[:info]
    assert_equal ['warn msg'], by[:warn]
    assert_equal ['error msg'], by[:error]
  end

  def test_unknown_level_falls_back_to_warn
    r = Paybridge::Report.new
    r.warn('x', level: :bogus)
    assert_equal :warn, r.diagnostics.first.level
  end
end
