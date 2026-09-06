# frozen_string_literal: true

require 'minitest/autorun'
require 'json'
require_relative '../lib/paybridge'

# `<provider>.postman_collection.json` — импортируемая коллекция Postman v2.1.
class TestPostmanGenerator < Minitest::Test
  def collection(spec, provider)
    JSON.parse(Paybridge.generate(spec_path: spec, provider: provider)
                        .files["#{provider}.postman_collection.json"])
  end

  def test_valid_collection_structure
    c = collection(File.expand_path('../examples/provider_api.yaml', __dir__), 'novapay')
    assert_equal 'https://schema.getpostman.com/json/collection/v2.1.0/collection.json', c.dig('info', 'schema')
    names = c['item'].map { |i| i['name'] }
    assert(names.any? { |n| n.include?('Создание') })
    assert(names.any? { |n| n.include?('Статус') })

    create = c['item'].find { |i| i['name'].include?('Создание') }
    assert_equal 'POST', create.dig('request', 'method')
    assert_includes create.dig('request', 'url', 'raw'), '{{base_url}}/payouts'
    # авторизация как переменная, не хардкод секрета
    api = create['request']['header'].find { |h| h['key'] == 'X-API-Key' }
    assert_equal '{{api_key}}', api['value']
    # тело — валидный JSON-пример
    JSON.parse(create.dig('request', 'body', 'raw'))
  end

  def test_status_url_uses_operation_id_variable
    c = collection(File.expand_path('../examples/provider_api.yaml', __dir__), 'novapay')
    status = c['item'].find { |i| i['name'].include?('Статус') }
    assert_includes status.dig('request', 'url', 'raw'), '{{provider_operation_id}}'
  end

  def test_deterministic
    spec = File.expand_path('../examples/provider_api.yaml', __dir__)
    a = Paybridge.generate(spec_path: spec, provider: 'novapay').files['novapay.postman_collection.json']
    b = Paybridge.generate(spec_path: spec, provider: 'novapay').files['novapay.postman_collection.json']
    assert_equal a, b
  end

  # Пустое тело печатается детерминированно как "{}" — не "{\n}", который
  # JSON.pretty_generate выдаёт в чистом Ruby (расхождение golden CI vs Windows).
  def test_empty_body_is_environment_independent
    c = collection(File.expand_path('../examples/swiftpay_api.yaml', __dir__), 'swiftpay')
    raw = c['item'].find { |i| i['name'].include?('Создание') }.dig('request', 'body', 'raw')
    assert_equal '{}', raw
  end
end
