# frozen_string_literal: true

require 'minitest/autorun'
require 'webrick'
require_relative '../lib/paybridge'

# Пункт паритета с конкурентами: спецификация может передаваться по http(s) URL.
class TestUrlSpec < Minitest::Test
  def with_server(content, allow_private: true)
    previous = ENV['PAYBRIDGE_ALLOW_PRIVATE_SPEC_URLS']
    ENV['PAYBRIDGE_ALLOW_PRIVATE_SPEC_URLS'] = '1' if allow_private
    ENV.delete('PAYBRIDGE_ALLOW_PRIVATE_SPEC_URLS') unless allow_private
    server = WEBrick::HTTPServer.new(
      Port: 0, BindAddress: '127.0.0.1',
      Logger: WEBrick::Log.new(File::NULL), AccessLog: []
    )
    server.mount_proc('/spec.yaml') do |_req, res|
      res['Content-Type'] = 'text/yaml'
      res.body = content
    end
    port = server.listeners.first.addr[1]
    thread = Thread.new { server.start }
    yield "http://127.0.0.1:#{port}/spec.yaml"
  ensure
    server&.shutdown
    thread&.join
    if previous
      ENV['PAYBRIDGE_ALLOW_PRIVATE_SPEC_URLS'] = previous
    else
      ENV.delete('PAYBRIDGE_ALLOW_PRIVATE_SPEC_URLS')
    end
  end

  def test_generate_from_url
    yaml = File.read(File.expand_path('../examples/provider_api.yaml', __dir__))
    with_server(yaml) do |url|
      gen = Paybridge.generate(spec_path: url, provider: 'novapay')
      assert_includes gen.files.keys, 'novapay_service.rb'
      refute_empty gen.endpoints
    end
  end

  def test_parse_only_from_url
    yaml = File.read(File.expand_path('../examples/provider_api.yaml', __dir__))
    with_server(yaml) do |url|
      model = Paybridge.parse_only(spec_path: url, provider: 'novapay')
      assert_equal 'X-API-Key', model.dig(:auth, :header)
    end
  end

  def test_unreachable_url_is_generation_error
    err = assert_raises(Paybridge::GenerationError) do
      Paybridge.generate(spec_path: 'http://127.0.0.1:1/none.yaml', provider: 'novapay')
    end
    assert_match(/URL/i, err.message)
  end

  def test_local_url_is_rejected_by_default
    yaml = File.read(File.expand_path('../examples/provider_api.yaml', __dir__))
    with_server(yaml, allow_private: false) do |url|
      err = assert_raises(Paybridge::GenerationError) do
        Paybridge.generate(spec_path: url, provider: 'novapay')
      end
      assert_match(/локальный|служебный/i, err.message)
    end
  end

  def test_url_credentials_are_rejected
    err = assert_raises(Paybridge::GenerationError) do
      Paybridge.generate(spec_path: 'https://user:pass@example.com/spec.yaml', provider: 'novapay')
    end
    assert_match(/credentials/i, err.message)
  end
end
