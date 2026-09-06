# frozen_string_literal: true

require 'minitest/autorun'
require 'tempfile'
require 'yaml'
require_relative '../lib/paybridge'

class TestParserWarnings < Minitest::Test
  def base
    YAML.safe_load(File.read(File.expand_path('../examples/provider_api.yaml', __dir__)), aliases: true)
  end

  def parse(doc)
    file = Tempfile.new(['warn', '.yaml'])
    file.write(YAML.dump(doc))
    file.rewind
    Paybridge.parse_only(spec_path: file.path, provider: 'warnpay')
  ensure
    file.close!
  end

  def test_warns_about_one_of_request_schema
    doc = base
    schema = doc['paths']['/payouts']['post']['requestBody']['content']['application/json']['schema']
    doc['paths']['/payouts']['post']['requestBody']['content']['application/json']['schema'] = {
      'oneOf' => [schema, { 'type' => 'object', 'properties' => { 'token' => { 'type' => 'string' } } }]
    }

    model = parse(doc)

    assert model[:warnings].any? { |message| message.include?('oneOf') }
  end

  def test_warns_about_external_ref
    doc = base
    doc['paths']['/payouts']['post']['requestBody']['content']['application/json']['schema'] = {
      '$ref' => 'https://example.test/schema.yaml#/CreatePayoutRequest'
    }

    model = parse(doc)

    assert model[:warnings].any? { |message| message.include?('Внешняя ссылка') }
  end

  def test_warns_about_ambiguous_create_endpoint_selection
    doc = base
    doc['paths']['/payments'] = doc['paths']['/payouts']

    model = parse(doc)

    assert model[:warnings].any? { |message| message.include?('несколько методов создания операции') }
  end
end
