# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../lib/paybridge/line_index'

class TestLineIndex < Minitest::Test
  YAML = <<~Y
    openapi: 3.0.3
    paths:
      /pay:
        post:
          operationId: create
    components:
      securitySchemes:
        Key:
          type: apiKey
  Y

  def idx = Paybridge::LineIndex.new(YAML)

  def test_line_for_nested_path
    assert_equal 2, idx.line_for('paths')            # строка 2 (1-based)
    assert_equal 3, idx.line_for('paths', '/pay')
    assert_equal 4, idx.line_for('paths', '/pay', 'post')
    assert_equal 8, idx.line_for('components', 'securitySchemes', 'Key')
  end

  def test_missing_path_is_nil
    assert_nil idx.line_for('paths', '/nope')
    assert_nil idx.line_for('nope')
  end

  def test_malformed_yaml_does_not_raise
    bad = Paybridge::LineIndex.new("\x00\x01 not: [valid")
    assert_nil bad.line_for('anything')
  end
end
