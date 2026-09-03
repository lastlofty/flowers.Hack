# frozen_string_literal: true

require 'minitest/autorun'
require 'rack/test'
require 'json'
require 'tempfile'
require_relative '../app/api'

class APITest < Minitest::Test
  include Rack::Test::Methods

  def app
    Paybridge::API
  end

  def spec_upload
    path = File.expand_path('../examples/provider_api.yaml', __dir__)
    Rack::Test::UploadedFile.new(path, 'application/x-yaml')
  end

  def test_health
    get '/api/health'
    assert_equal 200, last_response.status
    assert_equal 'ok', JSON.parse(last_response.body)['status']
  end

  def test_generate_happy_path
    post '/api/integrations', spec: spec_upload, provider: 'novapay'
    assert_equal 201, last_response.status
    body = JSON.parse(last_response.body)
    assert_equal 'novapay', body['provider']
    assert_includes body['files'], 'novapay_service.rb'
    refute_empty body['endpoints']
  end

  def test_generate_then_fetch_and_download
    post '/api/integrations', spec: spec_upload, provider: 'novapay'
    id = JSON.parse(last_response.body)['id']

    get "/api/integrations/#{id}"
    assert_equal 200, last_response.status

    get "/api/integrations/#{id}/files/novapay_service.rb"
    assert_equal 200, last_response.status
    assert_match(/module Provider/, last_response.body)

    get "/api/integrations/#{id}/archive"
    assert_equal 200, last_response.status
    assert_equal 'application/zip', last_response.content_type
  end

  def test_invalid_provider
    post '/api/integrations', spec: spec_upload, provider: 'Nova Pay!'
    assert_equal 400, last_response.status
  end

  def test_missing_spec
    post '/api/integrations', provider: 'novapay'
    assert_equal 400, last_response.status
  end

  def test_bad_yaml_returns_422
    file = Tempfile.new(['bad', '.yaml'])
    file.write("openapi: [unclosed\n")
    file.rewind
    upload = Rack::Test::UploadedFile.new(file.path, 'application/x-yaml')

    post '/api/integrations', spec: upload, provider: 'novapay'
    assert_equal 422, last_response.status
    assert_equal 'generation_failed', JSON.parse(last_response.body).dig('error', 'code')
  ensure
    file.close!
  end

  def test_unknown_integration_404
    get '/api/integrations/int_deadbeef'
    assert_equal 404, last_response.status
  end
end
