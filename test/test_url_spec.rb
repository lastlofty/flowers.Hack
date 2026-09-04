# frozen_string_literal: true

require 'minitest/autorun'
require 'webrick'
require_relative '../lib/paybridge'

# Пункт паритета с конкурентами: спецификация может передаваться по http(s) URL.
class TestUrlSpec < Minitest::Test
  def with_server(content)
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
    server.shutdown
    thread&.join
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
end
