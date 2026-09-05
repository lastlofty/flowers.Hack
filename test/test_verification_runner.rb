# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'tmpdir'
require_relative '../lib/paybridge'

class TestVerificationRunner < Minitest::Test
  def setup
    @root = Dir.mktmpdir('paybridge_runner_')
    File.write(File.join(@root, 'placeholder'), 'input')
  end

  def teardown
    FileUtils.remove_entry(@root) if Dir.exist?(@root)
  end

  def test_command_has_required_isolation_flags_and_read_only_input
    runner = Paybridge::VerificationRunner.new
    command = runner.send(:command, @root, File.join(@root, 'cid'))
    joined = command.join(' ')

    assert_includes joined, '--network none'
    assert_includes joined, '--read-only'
    assert_includes joined, '--cap-drop ALL'
    assert_includes joined, '--security-opt no-new-privileges'
    assert_includes joined, '--pids-limit 64'
    assert_includes joined, '--memory 128m'
    assert_includes joined, "src=#{@root},dst=/input,readonly"
  end

  def test_unavailable_has_no_local_fallback
    runner = Paybridge::VerificationRunner.new(docker: File.join(@root, 'missing-docker'))
    refute runner.available?
    assert_raises(Paybridge::VerificationRunner::Unavailable) { runner.run(@root) }
  end

  def test_timeout_terminates_runner
    docker = fake_docker(<<~'SH')
      if [ "$1" = "image" ]; then exit 0; fi
      if [ "$1" = "run" ]; then sleep 5; exit 0; fi
      exit 0
    SH
    runner = Paybridge::VerificationRunner.new(docker: docker, timeout: 0.1)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    assert_raises(Paybridge::VerificationRunner::TimedOut) { runner.run(@root) }
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 2
  end

  private

  def fake_docker(body)
    path = File.join(@root, 'docker')
    File.write(path, "#!/bin/sh\n#{body}")
    FileUtils.chmod(0o755, path)
    path
  end
end
