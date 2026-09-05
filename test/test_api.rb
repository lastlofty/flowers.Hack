# frozen_string_literal: true

require 'minitest/autorun'
require 'rack/test'
require 'json'
require 'tempfile'
require 'tmpdir'
require_relative '../app/api'

class APITest < Minitest::Test
  include Rack::Test::Methods

  class FakeRunner
    def available? = true

    def run(_dir)
      test_case = Paybridge::Verifier::Case.new(
        name: 'create_request.response_201', status: 'passed', ok: true, detail: 'ok'
      )
      Paybridge::Verifier::Report.new(cases: [test_case], checked_at: Time.now.utc.iso8601)
    end
  end

  class UnavailableRunner
    def available? = false
    def run(_dir) = raise(Paybridge::VerificationRunner::Unavailable, 'unavailable')
  end

  class TimeoutRunner
    def available? = true
    def run(_dir) = raise(Paybridge::VerificationRunner::TimedOut, 'timeout')
  end

  class BrokenRunner
    def available? = true
    def run(_dir) = raise('ARTIFICIAL_SECRET_VALUE')
  end

  def setup
    @storage = Dir.mktmpdir('paybridge_api_test_')
    Paybridge::API.set :store, Paybridge::Store.new(@storage)
    Paybridge::API.set :verification_runner, FakeRunner.new
  end

  def teardown
    FileUtils.remove_entry(@storage) if @storage && Dir.exist?(@storage)
  end

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
    assert_equal true, JSON.parse(last_response.body)['verification_available']
    assert_match(/\Areq_[0-9a-f]{24}\z/, JSON.parse(last_response.body)['request_id'])
  end

  def test_generate_happy_path
    post '/api/integrations', spec: spec_upload, provider: 'novapay'
    assert_equal 201, last_response.status
    body = JSON.parse(last_response.body)
    assert_equal 'novapay', body['provider']
    assert_includes body['files'], 'novapay_service.rb'
    refute_empty body['endpoints']
    assert_equal true, body['valid']
    assert_nil body['syntax_error']
    assert_equal 'not_run', body.dig('verification', 'status')
  end

  def test_validate_returns_model_without_saving_integration
    storage = File.expand_path('../storage', __dir__)
    before = Dir.glob(File.join(storage, 'int_*')).sort

    post '/api/validate', spec: spec_upload, provider: 'novapay'

    assert_equal 200, last_response.status
    body = JSON.parse(last_response.body)
    assert_equal 'novapay', body['provider']
    refute_empty body['endpoints']
    assert_equal 'apiKey', body.dig('auth', 'type')
    assert_equal 'in_progress', body.dig('status_map', 'pending')
    assert_equal 'insufficient_balance', body.dig('error_map', '402')
    assert_equal '/webhooks/payout', body.dig('webhook', 'path')
    assert_equal before, Dir.glob(File.join(storage, 'int_*')).sort
  end

  def test_validate_bad_yaml_returns_422
    file = Tempfile.new(['bad', '.yaml'])
    file.write("openapi: [unclosed\n")
    file.rewind
    upload = Rack::Test::UploadedFile.new(file.path, 'application/x-yaml')

    post '/api/validate', spec: upload, provider: 'novapay'

    assert_equal 422, last_response.status
    assert_equal 'validation_failed', JSON.parse(last_response.body).dig('error', 'code')
  ensure
    file.close!
  end

  def test_validate_rejects_too_large_file
    file = Tempfile.new(['large', '.yaml'])
    file.write('x' * (Paybridge::API::MAX_SPEC_BYTES + 1))
    file.rewind
    upload = Rack::Test::UploadedFile.new(file.path, 'application/x-yaml')

    post '/api/validate', spec: upload, provider: 'novapay'

    assert_equal 413, last_response.status
    assert_equal 'too_large', JSON.parse(last_response.body).dig('error', 'code')
  ensure
    file.close!
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

  def test_generate_then_verify
    post '/api/integrations', spec: spec_upload, provider: 'novapay'
    id = JSON.parse(last_response.body)['id']

    post "/api/integrations/#{id}/verify"

    assert_equal 200, last_response.status
    body = JSON.parse(last_response.body)
    assert_operator body['passed'], :>, 0
    assert_equal 0, body['failed']
    assert_equal 0, body['skipped']
    assert_equal 'passed', body['status']
    refute_empty body['cases']

    get "/api/integrations/#{id}"
    assert_equal 'passed', JSON.parse(last_response.body).dig('verification', 'status')
  end

  def test_model_and_list_survive_store_restart
    post '/api/integrations', spec: spec_upload, provider: 'novapay'
    id = JSON.parse(last_response.body)['id']

    get "/api/integrations/#{id}/model"
    assert_equal 200, last_response.status
    assert_equal 'novapay', JSON.parse(last_response.body)['provider']

    Paybridge::API.set :store, Paybridge::Store.new(@storage)
    get "/api/integrations/#{id}"
    assert_equal 200, last_response.status

    get '/api/integrations?page=1&per_page=20'
    body = JSON.parse(last_response.body)
    assert_equal 1, body['total']
    assert_equal id, body.dig('items', 0, 'id')
  end

  def test_invalid_pagination
    get '/api/integrations?page=0&per_page=101'
    assert_equal 400, last_response.status
    assert_equal 'invalid_pagination', JSON.parse(last_response.body).dig('error', 'code')
  end

  def test_verify_unavailable_is_503_and_persisted
    post '/api/integrations', spec: spec_upload, provider: 'novapay'
    id = JSON.parse(last_response.body)['id']
    Paybridge::API.set :verification_runner, UnavailableRunner.new

    post "/api/integrations/#{id}/verify"
    assert_equal 503, last_response.status
    assert_equal 'verification_unavailable', JSON.parse(last_response.body).dig('error', 'code')

    get "/api/integrations/#{id}"
    assert_equal 'unavailable', JSON.parse(last_response.body).dig('verification', 'status')
  end

  def test_verify_timeout_is_504_and_not_success
    post '/api/integrations', spec: spec_upload, provider: 'novapay'
    id = JSON.parse(last_response.body)['id']
    Paybridge::API.set :verification_runner, TimeoutRunner.new

    post "/api/integrations/#{id}/verify"
    assert_equal 504, last_response.status
    assert_equal 'verification_timeout', JSON.parse(last_response.body).dig('error', 'code')

    get "/api/integrations/#{id}"
    assert_equal 'error', JSON.parse(last_response.body).dig('verification', 'status')
  end

  def test_generation_timeout_is_504
    original = Paybridge.method(:parse_only)
    Paybridge.define_singleton_method(:parse_only) do |**_arguments|
      sleep 0.2
    end
    Paybridge::API.set :generation_timeout, 0.01

    post '/api/validate', spec: spec_upload, provider: 'novapay'
    assert_equal 504, last_response.status
    assert_equal 'generation_timeout', JSON.parse(last_response.body).dig('error', 'code')
  ensure
    Paybridge.define_singleton_method(:parse_only, original) if original
    Paybridge::API.set :generation_timeout, 10
  end

  def test_request_id_is_echoed_and_in_error_body
    get '/api/health', {}, 'HTTP_X_REQUEST_ID' => 'req_client_123'
    assert_equal 'req_client_123', last_response.headers['X-Request-ID']
    assert_equal 'req_client_123', JSON.parse(last_response.body)['request_id']

    post '/api/integrations', { provider: 'novapay' }, 'HTTP_X_REQUEST_ID' => 'req_error_123'
    assert_equal 'req_error_123', JSON.parse(last_response.body)['request_id']
  end

  def test_unexpected_error_is_500_without_internal_detail
    post '/api/integrations', spec: spec_upload, provider: 'novapay'
    id = JSON.parse(last_response.body)['id']
    Paybridge::API.set :verification_runner, BrokenRunner.new

    post "/api/integrations/#{id}/verify"
    assert_equal 500, last_response.status
    refute_includes last_response.body, 'ARTIFICIAL_SECRET_VALUE'
    assert_equal 'internal_error', JSON.parse(last_response.body).dig('error', 'code')
  end

  def test_invalid_provider
    post '/api/integrations', spec: spec_upload, provider: 'Nova Pay!'
    assert_equal 400, last_response.status
  end

  def test_validate_invalid_provider
    post '/api/validate', spec: spec_upload, provider: 'Nova Pay!'
    assert_equal 400, last_response.status
    assert_equal 'invalid_provider', JSON.parse(last_response.body).dig('error', 'code')
  end

  def test_missing_spec
    post '/api/integrations', provider: 'novapay'
    assert_equal 400, last_response.status
  end

  def test_validate_missing_spec
    post '/api/validate', provider: 'novapay'
    assert_equal 400, last_response.status
    assert_equal 'missing_spec', JSON.parse(last_response.body).dig('error', 'code')
  end

  def test_invalid_file_extension
    file = Tempfile.new(['spec', '.txt'])
    file.write("openapi: 3.0.3\n")
    file.rewind
    upload = Rack::Test::UploadedFile.new(file.path, 'text/plain')

    post '/api/validate', spec: upload, provider: 'novapay'

    assert_equal 400, last_response.status
    assert_equal 'invalid_type', JSON.parse(last_response.body).dig('error', 'code')
  ensure
    file.close!
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
