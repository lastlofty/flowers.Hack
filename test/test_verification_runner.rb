# frozen_string_literal: true

require 'minitest/autorun'
require 'rbconfig'
require_relative '../app/verification_runner'
require_relative '../lib/paybridge'

class VerificationRunnerTest < Minitest::Test
  def setup
    @runner = Paybridge::VerificationRunner.new
  end

  def test_child_process_timeout
    assert_raises(Paybridge::VerificationRunner::Deadline) do
      @runner.capture([RbConfig.ruby, '-e', 'sleep 30'], seconds: 0.3)
    end
    output, ok = @runner.capture([RbConfig.ruby, '-e', 'print "alive"'])
    assert ok
    assert_equal 'alive', output
  end

  def test_output_is_bounded
    assert_raises(Paybridge::VerificationRunner::Failure) do
      @runner.capture([RbConfig.ruby, '-e', '$stdout.sync = true; loop { print "x" * 8192 }'], limit: 1024)
    end
  end

  def test_report_counts_are_computed_from_cases
    report = @runner.parse_report(JSON.generate(passed: 100, cases: [
      { name: 'ok', ok: true, detail: 'executed' },
      { name: 'bad', ok: false, detail: 'mismatch' }
    ]))
    assert_equal 1, report[:passed]
    assert_equal 1, report[:failed]
  end

  def test_invalid_and_empty_reports_are_rejected
    ['not json', 'null', '{}', '{"cases":[]}', '{"cases":[{"ok":"true"}]}'].each do |output|
      assert_raises(Paybridge::VerificationRunner::Failure) { @runner.parse_report(output) }
    end
  end

  def test_real_container_boundaries_and_recovery
    skip 'Set PAYBRIDGE_DOCKER_TESTS=1 after building the verification image' unless ENV['PAYBRIDGE_DOCKER_TESTS'] == '1'
    assert @runner.capability[:verification_available], 'Docker/image unavailable'
    script = <<~'RUBY'
      require 'socket'
      raise 'root user' if Process.uid == 0
      begin
        File.write('/runner/forbidden', 'x')
        abort 'writable root'
      rescue Errno::EROFS, Errno::EACCES
      end
      begin
        Socket.tcp('1.1.1.1', 443, connect_timeout: 1) { abort 'network allowed' }
      rescue SystemCallError, IOError
      end
      abort 'host mounted' if File.exist?('/var/run/docker.sock')
      print 'isolated'
    RUBY
    output, ok = @runner.in_container([Paybridge::VerificationRunner::IMAGE, 'ruby', '-e', script])
    assert ok, output
    assert_equal 'isolated', output
    assert_raises(Paybridge::VerificationRunner::Deadline) do
      @runner.in_container([Paybridge::VerificationRunner::IMAGE, 'ruby', '-e', 'sleep 60'], seconds: 1)
    end
    assert @runner.capability[:verification_available], 'runner failed to recover'
  end

  def test_real_generated_services_in_separate_containers
    skip 'Set PAYBRIDGE_DOCKER_TESTS=1 after building the verification image' unless ENV['PAYBRIDGE_DOCKER_TESTS'] == '1'
    { 'novapay' => 'provider_api', 'bluepay' => 'bluepay_api',
      'swiftpay' => 'swiftpay_api', 'europay' => 'europay_api' }.each do |provider, spec|
      generation = Paybridge.generate(spec_path: File.expand_path("../examples/#{spec}.yaml", __dir__), provider: provider)
      Dir.mktmpdir do |dir|
        generation.files.each { |name, content| File.write(File.join(dir, name), content) }
        FileUtils.cp(File.expand_path('../lib/paybridge/templates/base_service.rb', __dir__), dir)
        report = @runner.run(dir, provider)
        assert_operator report[:passed], :>, 0, provider
        assert_equal 0, report[:failed], "#{provider}: #{report[:cases]}"
      end
    end
  end
end
