# frozen_string_literal: true

require 'minitest/autorun'
require 'fileutils'
require 'tmpdir'
require 'securerandom'
require 'tempfile'
require_relative '../lib/paybridge'

# Прогон fixtures против сгенерированного сервиса: генерируем интеграцию в temp,
# кладём base_service рядом и проверяем, что все сценарии проходят.
class TestVerifier < Minitest::Test
  def verify(spec_file, provider)
    dir = generated_dir(spec_file, provider)
    Paybridge::Verifier.new(dir).run
  end

  def generated_dir(spec_file, provider)
    unique_provider = "#{provider}_#{SecureRandom.hex(3)}"
    dir = Dir.mktmpdir("pb_#{unique_provider}_")
    gen = Paybridge.generate(
      spec_path: File.expand_path("../examples/#{spec_file}", __dir__),
      provider: unique_provider
    )
    gen.files.each { |name, body| File.write(File.join(dir, name), body) }
    FileUtils.cp(Paybridge::BASE_SERVICE, File.join(dir, 'base_service.rb'))
    dir
  end

  def test_novapay_scenarios_pass
    report = verify('provider_api.yaml', 'novapay')
    refute_empty report.cases
    assert_equal 0, report.failed,
                 "провал: #{report.cases.select { |item| item.status == 'failed' }.map { |c| "#{c.name} #{c.detail}" }.join('; ')}"
  end

  def test_bluepay_scenarios_pass
    report = verify('bluepay_api.yaml', 'bluepay')
    refute_empty report.cases
    assert_equal 0, report.failed
  end

  def test_europay_scenarios_pass
    report = verify('europay_api.yaml', 'europay')
    refute_empty report.cases
    assert_equal 0, report.failed
  end

  def test_report_counts
    report = verify('provider_api.yaml', 'novapay')
    assert_equal report.cases.size, report.passed + report.failed + report.skipped
  end

  def test_checks_conditions_and_invalid_signature
    report = verify('provider_api.yaml', 'novapay')
    names = report.cases.map(&:name)

    assert_includes names, 'check_conditions.normal'
    assert_includes names, 'callback.invalid_signature'
    assert_equal 'passed', report.cases.find { |test_case| test_case.name == 'callback.invalid_signature' }.status
  end

  def test_wrong_outgoing_url_fails_but_other_cases_continue
    dir = generated_dir('provider_api.yaml', 'wrong_url')
    service = Dir[File.join(dir, '*_service.rb')].reject { |path| path.end_with?('base_service.rb') }.first
    body = File.read(service).sub('https://api.sandbox.novapay.example/v1', 'https://wrong.example')
    File.write(service, body)

    report = Paybridge::Verifier.new(dir).run
    assert_operator report.failed, :>, 0
    assert report.cases.any? { |item| item.name.start_with?('callback.') && item.status == 'passed' }
  end

  def test_wrong_header_or_amount_fails
    replacements = [
      ["'X-API-Key'", "'Wrong-Key'"],
      ['(operation.amount * 100).to_i', '(operation.amount * 10).to_i']
    ]
    replacements.each_with_index do |(from, to), index|
      dir = generated_dir('provider_api.yaml', "wrong_request_#{index}")
      service = Dir[File.join(dir, '*_service.rb')].reject { |path| path.end_with?('base_service.rb') }.first
      File.write(service, File.read(service).sub(from, to))

      report = Paybridge::Verifier.new(dir).run
      assert report.cases.any? { |item| item.name == 'create_request.response_201' && item.status == 'failed' }
    end
  end

  def test_create_success_200_does_not_invent_201
    source = File.read(File.expand_path('../examples/provider_api.yaml', __dir__))
    file = Tempfile.new(['success_200', '.yaml'])
    file.write(source.gsub(/^(\s+)'201':/, "\\1'200':"))
    file.close
    provider = "success_200_#{SecureRandom.hex(3)}"
    dir = Dir.mktmpdir("pb_#{provider}_")
    generation = Paybridge.generate(spec_path: file.path, provider: provider)
    generation.files.each { |name, body| File.write(File.join(dir, name), body) }
    FileUtils.cp(Paybridge::BASE_SERVICE, File.join(dir, 'base_service.rb'))

    report = Paybridge::Verifier.new(dir).run
    names = report.cases.map(&:name)
    assert_includes names, 'create_request.response_200'
    refute_includes names, 'create_request.response_201'
  ensure
    file&.unlink
  end

  def test_idempotent_and_ordinary_409_are_separate_cases
    dir = generated_dir('provider_api.yaml', 'conflict_cases')
    report = Paybridge::Verifier.new(dir).run
    idempotent = report.cases.find { |item| item.name.end_with?('response_409_idempotent') }
    conflict = report.cases.find { |item| item.name.end_with?('response_409_conflict') }
    assert_equal 'passed', idempotent.status
    assert_equal 'passed', conflict.status
  end

  def test_raw_body_with_whitespace_is_signed_without_reserialization
    dir = Dir.mktmpdir('pb_raw_body_')
    FileUtils.cp(Paybridge::BASE_SERVICE, File.join(dir, 'base_service.rb'))
    raw_body = "{\n  \"event\": \"paid\",\n  \"status\": \"paid\"\n}\n"
    fixtures = {
      'provider' => 'raw_body',
      'callback' => {
        'signature_header' => 'X-Signature', 'signature_alg' => 'SHA256', 'signature_encoding' => 'hex',
        'paid' => {
          'payload' => { 'event' => 'paid', 'status' => 'paid' },
          'raw_body' => raw_body, 'expected_operation_status' => 'approved'
        }
      }
    }
    File.write(File.join(dir, 'fixtures.json'), JSON.generate(fixtures))
    File.write(File.join(dir, 'raw_body_service.rb'), <<~'RUBY')
      require 'json'
      require 'openssl'
      module Provider
        class RawBodyService < BaseService
          def process_callback(raw_body, signature, _headers = {})
            expected = OpenSSL::HMAC.hexdigest('SHA256', 'test_secret', raw_body)
            valid = signature.bytesize == expected.bytesize && OpenSSL.fixed_length_secure_compare(expected, signature)
            raise UnauthorizedError unless valid

            JSON.parse(raw_body)
            success(status: 'approved')
          end
        end
      end
    RUBY

    report = Paybridge::Verifier.new(dir).run
    assert_equal 'passed', report.cases.find { |item| item.name == 'callback.paid' }.status
    assert_equal 'passed', report.cases.find { |item| item.name == 'callback.invalid_signature' }.status
  end

  # Регрессия YooKassa: HTTP Basic (credentials_field=password). Verifier должен
  # выбирать Basic по auth.scheme, а не угадывать Bearer по credentials_field.
  BASIC_SPEC = <<~YAML
    openapi: 3.0.3
    info: { title: T, version: "1.0.0" }
    servers: [ { url: https://x.example/v1 } ]
    paths:
      /pay:
        post:
          operationId: create
          security: [ { Basic: [] } ]
          requestBody:
            required: true
            content: { application/json: { schema: { type: object, required: [amount], properties: { amount: {type: integer, minimum: 100} } } } }
          responses:
            '200': { description: ok, content: { application/json: { schema: { type: object, properties: { id: {type: string}, status: {type: string, enum: [pending, completed]} } } } } }
      /pay/{id}:
        get:
          operationId: get
          security: [ { Basic: [] } ]
          parameters: [ { name: id, in: path, required: true, schema: { type: string } } ]
          responses:
            '200': { description: ok, content: { application/json: { schema: { type: object, properties: { id: {type: string}, status: {type: string, enum: [pending, completed]} } } } } }
    components:
      securitySchemes:
        Basic: { type: http, scheme: basic }
  YAML

  def test_http_basic_auth_verifies_without_guessing_bearer
    file = Tempfile.new(['basic', '.yaml'])
    file.write(BASIC_SPEC)
    file.close
    provider = "basicpay_#{SecureRandom.hex(3)}"
    dir = Dir.mktmpdir("pb_#{provider}_")
    gen = Paybridge.generate(spec_path: file.path, provider: provider)
    gen.files.each { |name, body| File.write(File.join(dir, name), body) }
    FileUtils.cp(Paybridge::BASE_SERVICE, File.join(dir, 'base_service.rb'))

    # v3-контракт объявляет схему явно.
    fixtures = JSON.parse(gen.files['fixtures.json'])
    assert_equal 3, fixtures['contract_version']
    assert_equal 'basic', fixtures.dig('auth', 'scheme')
    assert_equal [200], fixtures.dig('create_request', 'success_codes')

    report = Paybridge::Verifier.new(dir).run
    assert_equal 0, report.failed,
                 "провал: #{report.cases.select { |c| c.status == 'failed' }.map { |c| "#{c.name} #{c.detail}" }.join('; ')}"
    assert_equal 'passed', report.cases.find { |c| c.name == 'create_request.response_200' }.status
  ensure
    file&.unlink
  end

  def test_exception_in_one_scenario_is_failed_and_does_not_abort_report
    dir = generated_dir('provider_api.yaml', 'raises_once')
    service = Dir[File.join(dir, '*_service.rb')].reject { |path| path.end_with?('base_service.rb') }.first
    body = File.read(service).sub('def fetch_status(operation)', "def fetch_status(operation)\n      raise 'scenario boom'")
    File.write(service, body)

    report = Paybridge::Verifier.new(dir).run
    failed = report.cases.find { |item| item.name == 'fetch_status.response_200' }
    assert_equal 'failed', failed.status
    assert report.cases.any? { |item| item.name.start_with?('callback.') && item.status == 'passed' }
  end
end
