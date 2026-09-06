# frozen_string_literal: true

require 'minitest/autorun'
require 'fileutils'
require 'tmpdir'
require 'securerandom'
require_relative '../lib/paybridge'

# cancel_request генерируется, когда в спеке есть метод отмены, и проверяется
# verify. Провайдеры без отмены его не получают (метод не в обязательном контракте).
class TestCancel < Minitest::Test
  def generate(spec_rel, provider)
    Paybridge.generate(spec_path: File.expand_path("../examples/#{spec_rel}", __dir__), provider: provider)
  end

  def test_cancel_generated_when_endpoint_present
    code = generate('provider_api.yaml', 'novapay').files['novapay_service.rb']
    assert_includes code, 'def cancel_request'
    assert_includes code, '/cancel'
  end

  def test_cancel_absent_when_no_endpoint
    code = generate('bluepay_api.yaml', 'bluepay').files['bluepay_service.rb']
    refute_includes code, 'def cancel_request'
  end

  def test_cancel_is_verified
    provider = "cancelpay_#{SecureRandom.hex(3)}"
    dir = Dir.mktmpdir("pb_#{provider}_")
    gen = Paybridge.generate(spec_path: File.expand_path('../examples/provider_api.yaml', __dir__), provider: provider)
    gen.files.each { |name, body| File.binwrite(File.join(dir, name), body) }
    FileUtils.cp(Paybridge::BASE_SERVICE, File.join(dir, 'base_service.rb'))

    report = Paybridge::Verifier.new(dir).run
    cancel = report.cases.find { |c| c.name == 'cancel_request.response_200' }
    assert_equal 'passed', cancel.status, cancel.detail
    assert_equal 0, report.failed
  end
end
