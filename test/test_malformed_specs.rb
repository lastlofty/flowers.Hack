# frozen_string_literal: true

require 'minitest/autorun'
require 'yaml'
require 'tempfile'
require_relative '../lib/paybridge'

# Регрессия по находкам coverage-guided фаззера (tools/fuzz_generator.rb):
# любой битый по ТИПАМ ввод должен давать GenerationError, а не сырой краш
# (NoMethodError/TypeError/...). Каждый кейс — узел спеки не того типа.
class TestMalformedSpecs < Minitest::Test
  def base
    YAML.safe_load(
      File.read(File.expand_path('../examples/provider_api.yaml', __dir__)), aliases: true
    )
  end

  def dup(doc)
    Marshal.load(Marshal.dump(doc))
  end

  def generate(doc)
    file = Tempfile.new(['m', '.yaml'])
    file.write(YAML.dump(doc))
    file.rewind
    Paybridge.generate(spec_path: file.path, provider: 'malformed')
  ensure
    file.close!
  end

  # Каждый corruption -> ожидаем GenerationError, НИКОГДА иное исключение.
  def assert_generation_error(doc, label)
    generate(doc)
    # генерация могла и пройти (некоторые искажения безвредны) — это ок
  rescue Paybridge::GenerationError
    pass
  rescue StandardError => e
    flunk "#{label}: ожидался GenerationError, получен #{e.class}: #{e.message}"
  end

  def test_properties_not_hash
    doc = dup(base)
    doc['components']['schemas']['CreatePayoutRequest']['properties'] = true
    assert_generation_error(doc, 'properties=true')
  end

  def test_property_value_not_hash
    doc = dup(base)
    doc['components']['schemas']['CreatePayoutRequest']['properties']['amount'] = true
    assert_generation_error(doc, 'property=true')
  end

  def test_status_enum_not_array
    doc = dup(base)
    doc['components']['schemas']['PayoutResponse']['properties']['status']['enum'] = 'notarray'
    assert_generation_error(doc, 'enum=string')
  end

  def test_parameters_not_array
    doc = dup(base)
    doc['paths']['/payouts']['post']['parameters'] = { 'wrong' => 1 }
    assert_generation_error(doc, 'parameters=hash')
  end

  def test_security_scheme_not_hash
    doc = dup(base)
    doc['components']['securitySchemes']['ApiKeyAuth'] = 'string'
    assert_generation_error(doc, 'securityScheme=string')
  end

  def test_servers_not_array
    doc = dup(base)
    doc['servers'] = { 'a' => 1 }
    assert_generation_error(doc, 'servers=hash')
  end

  def test_server_item_not_hash
    doc = dup(base)
    doc['servers'] = ['just-a-string']
    assert_generation_error(doc, 'server=string')
  end

  def test_responses_not_hash
    doc = dup(base)
    doc['paths']['/payouts']['post']['responses'] = %w[a b]
    assert_generation_error(doc, 'responses=array')
  end

  def test_recipient_not_hash
    doc = dup(base)
    doc['components']['schemas']['CreatePayoutRequest']['properties']['recipient'] = true
    assert_generation_error(doc, 'recipient=true')
  end

  def test_minimum_not_number
    doc = dup(base)
    doc['components']['schemas']['CreatePayoutRequest']['properties']['amount']['minimum'] = 'abc'
    assert_generation_error(doc, 'minimum=string')
  end

  def test_info_not_hash
    doc = dup(base)
    doc['info'] = 'just a title'
    assert_generation_error(doc, 'info=string')
  end

  def test_paths_operation_not_hash
    doc = dup(base)
    doc['paths']['/payouts']['post'] = true
    assert_generation_error(doc, 'operation=true')
  end
end
