# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../lib/paybridge'

# Регрессия на дыру из разбора полётов: провайдер с Bearer-авторизацией
# (`type: http, scheme: bearer`) — раньше давал битый `auth_headers`.
class TestBearerAuth < Minitest::Test
  SPEC = File.expand_path('../examples/swiftpay_api.yaml', __dir__)

  def spec
    Paybridge::SpecParser.new(SPEC, 'swiftpay', Paybridge.load_config).parse
  end

  def code
    Paybridge::Generators::ServiceGenerator.new(spec, config: Paybridge.load_config).render
  end

  def test_auth_parsed_as_bearer
    s = spec
    assert_equal 'http', s.auth.scheme_type
    assert_equal 'Authorization', s.auth.header_name
    assert_equal 'token', s.auth.credentials_field
  end

  def test_generated_uses_bearer_header
    assert_includes code, %q{'Authorization' => "Bearer #{provider.credentials.fetch('token')}"}
  end

  def test_no_webhook_means_no_signature_code
    refute_includes code, 'def process_callback'
    refute_includes code, 'verify_signature!'
  end

  def test_generation_compiles_and_has_files
    gen = Paybridge.generate(spec_path: SPEC, provider: 'swiftpay')
    assert gen.files['swiftpay_service.rb']
    assert_includes gen.files['swiftpay_service.rb'], 'class SwiftpayService < BaseService'
  end
end
