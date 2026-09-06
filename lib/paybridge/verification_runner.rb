# frozen_string_literal: true

require 'json'
require 'open3'
require 'tmpdir'

module Paybridge
  # Одноразовый Docker-контейнер: без сети/секретов/storage и без fallback.
  class VerificationRunner
    class Unavailable < StandardError; end
    class TimedOut < StandardError; end
    class ExecutionError < StandardError; end

    DEFAULT_IMAGE = 'ruby:3.2-bookworm'
    MAX_PROTOCOL_BYTES = 1_000_000
    MAX_DIAGNOSTIC_BYTES = 64_000
    DOCKER_PROBE_TIMEOUT = 3
    DOCKER_CLEANUP_TIMEOUT = 3

    def initialize(timeout: 10, image: ENV.fetch('PAYBRIDGE_VERIFY_IMAGE', DEFAULT_IMAGE), docker: 'docker')
      @timeout = Float(timeout)
      @image = image
      @docker = Array(docker)
    end

    def available?
      _out, _err, status, timed_out, = capture_process(
        docker_command('image', 'inspect', @image),
        timeout: DOCKER_PROBE_TIMEOUT,
        stdout_limit: MAX_DIAGNOSTIC_BYTES,
        stderr_limit: MAX_DIAGNOSTIC_BYTES
      )
      !timed_out && status&.success?
    rescue SystemCallError, ExecutionError
      false
    end

    def run(input_dir)
      raise Unavailable, 'Безопасная среда проверки недоступна' unless available?

      Dir.mktmpdir('paybridge_verify_') do |control_dir|
        cidfile = File.join(control_dir, 'container.cid')
        stdout, stderr, process_status, timed_out, truncated = capture_process(
          command(input_dir, cidfile),
          timeout: @timeout,
          stdout_limit: MAX_PROTOCOL_BYTES,
          stderr_limit: MAX_DIAGNOSTIC_BYTES
        )
        cleanup_container(cidfile)
        raise TimedOut, 'Проверка превысила ограничение времени' if timed_out
        raise ExecutionError, 'Протокол проверки превысил допустимый размер' if truncated
        raise ExecutionError, diagnostic_message(stderr) unless process_status&.success?

        payload = JSON.parse(stdout)
        raise ExecutionError, payload.dig('error', 'message') || 'Проверка не выполнена' if payload['status'] == 'error'

        Verifier::Report.from_h(payload.fetch('report'))
      rescue JSON::ParserError, KeyError
        raise ExecutionError, 'Среда проверки вернула некорректный протокол'
      ensure
        cleanup_container(cidfile) if cidfile
      end
    end

    private

    def command(input_dir, cidfile)
      verifier = File.expand_path('verifier.rb', __dir__)
      worker = File.expand_path('../../exe/paybridge_verify_worker', __dir__)
      docker_command('run', '--rm', '--cidfile', cidfile,
       '--network', 'none', '--read-only', '--cap-drop', 'ALL',
       '--security-opt', 'no-new-privileges', '--pids-limit', '64',
       '--memory', '128m', '--cpus', '0.5', '--user', '65534:65534',
       '--tmpfs', '/tmp:rw,noexec,nosuid,size=16m',
       '--mount', "type=bind,src=#{File.expand_path(input_dir)},dst=/input,readonly",
       '--mount', "type=bind,src=#{verifier},dst=/runner/verifier.rb,readonly",
       '--mount', "type=bind,src=#{worker},dst=/runner/worker.rb,readonly",
       @image, 'ruby', '/runner/worker.rb', '/input')
    end

    def docker_command(*arguments)
      @docker + arguments
    end

    def capture_process(command, timeout:, stdout_limit:, stderr_limit:)
      stdout = +''
      stderr = +''
      protocol_truncated = false
      status = nil
      timed_out = false
      Open3.popen3(clean_env, *command, *process_options) do |stdin, out, err, wait|
        stdin.close
        out_reader = bounded_reader(out, stdout, stdout_limit) { protocol_truncated = true }
        err_reader = bounded_reader(err, stderr, stderr_limit)
        unless wait.join(timeout)
          timed_out = true
          terminate(wait.pid)
        end
        status = wait.value
        out_reader.join
        err_reader.join
      end
      [stdout, stderr, status, timed_out, protocol_truncated]
    end

    def bounded_reader(io, target, limit, &on_truncate)
      Thread.new do
        while (chunk = io.read(16_384))
          remaining = limit - target.bytesize
          target << chunk.byteslice(0, remaining) if remaining.positive?
          on_truncate&.call if chunk.bytesize > remaining
        end
      rescue IOError
        nil
      end
    end

    def terminate(pid)
      if Gem.win_platform?
        Process.kill('KILL', pid)
      else
        Process.kill('TERM', -pid)
        sleep 0.1
        Process.kill('KILL', -pid)
      end
    rescue Errno::ESRCH
      nil
    end

    def cleanup_container(cidfile)
      return unless cidfile && File.file?(cidfile)

      cid = File.read(cidfile).strip
      return unless cid.match?(/\A[0-9a-f]{12,64}\z/)

      capture_process(
        docker_command('rm', '-f', cid),
        timeout: DOCKER_CLEANUP_TIMEOUT,
        stdout_limit: MAX_DIAGNOSTIC_BYTES,
        stderr_limit: MAX_DIAGNOSTIC_BYTES
      )
    rescue StandardError
      nil
    end

    def process_options
      options = { unsetenv_others: true }
      options[:pgroup] = true unless Gem.win_platform?
      [options]
    end

    def diagnostic_message(stderr)
      text = stderr.to_s.lines.last(3).join.strip
      return 'Среда проверки завершилась с ошибкой' if text.empty?

      "Среда проверки завершилась с ошибкой: #{text.slice(0, 300)}"
    end

    def clean_env
      env = { 'PATH' => ENV.fetch('PATH', '/usr/bin:/bin') }
      return env unless Gem.win_platform?

      %w[SystemRoot WINDIR ComSpec PATHEXT TEMP TMP USERPROFILE].each do |key|
        value = ENV[key]
        env[key] = value if value && !value.empty?
      end
      env
    end
  end
end
