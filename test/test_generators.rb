# frozen_string_literal: true

require 'minitest/autorun'
require 'json'
require 'tempfile'
require_relative '../lib/paybridge'

class TestGenerators < Minitest::Test
  def setup
    spec_path = File.expand_path('../examples/provider_api.yaml', __dir__)
    @config = Paybridge.load_config
    @spec = Paybridge::SpecParser.new(spec_path, 'novapay', @config).parse
  end

  def test_service_generation
    code = Paybridge::Generators::ServiceGenerator.new(@spec, config: @config).render
    assert_includes code, 'class NovapayService < BaseService'
    assert_includes code, "BASE_URL = ENV.fetch('NOVAPAY_BASE_URL'"
    assert_includes code, 'MIN_AMOUNT = 100000'
    assert_includes code, 'STATUS_MAP = {'
    assert_includes code, "'X-API-Key' => provider.credentials.fetch('api_key')"
    assert_includes code, "OpenSSL::HMAC.hexdigest('SHA256'"
    assert_includes code, "when 'payout.completed', 'payout.processing'"
    assert_includes code, "when 201, 409"
  end

  def test_docs_generation
    md = Paybridge::Generators::DocsGenerator.new(@spec, config: @config).render
    assert_includes md, '## Маппинг статусов'
    assert_includes md, '| completed | approved |'
    assert_includes md, 'X-NovaPay-Signature'
  end

  def test_fixtures_generation
    json = Paybridge::Generators::FixturesGenerator.new(@spec).render
    data = JSON.parse(json)
    assert_equal 'novapay', data['provider']
    assert data['create_request']['request']
    assert data['callback']
  end

  def test_facade_rejects_invalid_provider_name
    error = assert_raises(Paybridge::GenerationError) do
      Paybridge.generate(spec_path: File.expand_path('../examples/provider_api.yaml', __dir__), provider: 'Bad Name!')
    end
    assert_match(/provider/, error.message)
  end

  def test_generation_without_create_endpoint_has_clear_error
    file = Tempfile.new(['no_create', '.yaml'])
    file.write(<<~YAML)
      openapi: 3.0.3
      info: { title: Read Only, version: 1.0.0 }
      paths:
        /balance:
          get:
            responses: { '200': { description: ok } }
    YAML
    file.rewind

    error = assert_raises(Paybridge::GenerationError) do
      Paybridge.generate(spec_path: file.path, provider: 'readonly')
    end
    assert_match(/POST-метод создания/, error.message)
  ensure
    file.close!
  end
end
