# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../lib/paybridge/schema_validator'

class TestSchemaValidator < Minitest::Test
  SCHEMA = {
    'type' => 'object', 'required' => %w[amount],
    'properties' => {
      'amount' => { 'type' => 'integer' },
      'cur' => { 'type' => 'string', 'enum' => %w[RUB USD] },
      'items' => { 'type' => 'array', 'items' => { 'type' => 'object', 'required' => ['id'],
                                                   'properties' => { 'id' => { 'type' => 'string' } } } }
    }
  }.freeze

  def v(value) = Paybridge::SchemaValidator.errors(value, SCHEMA)

  def test_valid
    assert_empty v('amount' => 10, 'cur' => 'RUB', 'items' => [{ 'id' => 'x' }])
  end

  def test_missing_required
    assert(v({ 'cur' => 'RUB' }).any? { |e| e.include?('amount') && e.include?('обязательное') })
  end

  def test_wrong_type
    assert(v({ 'amount' => 'x' }).any? { |e| e.include?('целое') })
  end

  def test_enum_violation
    assert(v({ 'amount' => 1, 'cur' => 'EUR' }).any? { |e| e.include?('enum') })
  end

  def test_nested_array_item_error
    assert(v({ 'amount' => 1, 'items' => [{ 'id' => 5 }] }).any? { |e| e.include?('items[0]/id') })
  end

  def test_nil_is_lenient
    assert_empty Paybridge::SchemaValidator.errors(nil, SCHEMA)
  end
end
