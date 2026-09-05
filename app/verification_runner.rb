# frozen_string_literal: true

require 'json'
require 'open3'
require 'securerandom'
require 'tmpdir'
require 'fileutils'

module Paybridge
  # Never loads generated Ruby in the HTTP server. Docker is required;
  # no fallback to an unrestricted local Ruby process is allowed.
  class VerificationRunner
    IMAGE = 'paybridge-verifier:local'
    MAX_OUTPUT = 262_144
    MAX_INPUT = 4_000_000
    class Unavailable < StandardError; end
    class Failure < StandardError; end
    class Deadline < Failure; end
    class Busy < Failure; end

    def initialize
      @lock = Mutex.new
    end

    # Bounded subprocess output and wall time, including a noisy/crashed CLI.
    def capture(argv, seconds: 20, limit: MAX_OUTPUT)
      output = +''.b
      guard = Mutex.new
      overflow = false
      options = Gem.win_platform? ? {} : { pgroup: true }
      Open3.popen2e(*argv, **options) do |stdin, pipe, process|
        stdin.close
        reader = Thread.new do
          loop do
            chunk = pipe.readpartial(8192)
            guard.synchronize do
              remaining = limit - output.bytesize
              output << chunk.byteslice(0, remaining) if remaining.positive?
              overflow = true if chunk.bytesize > remaining
            end
          end
        rescue EOFError, IOError
          nil
        end
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
        begin
          loop do
            raise Failure, 'Превышен лимит вывода проверки.' if guard.synchronize { overflow }
            break unless process.alive? || reader.alive?
            raise Deadline, 'Превышено время проверки.' if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

            sleep 0.02
          end
          [output, process.value.success?]
        ensure
          if process.alive?
            begin
              Process.kill('KILL', Gem.win_platform? ? process.pid : -process.pid)
            rescue Errno::ESRCH
              nil
            end
          end
          reader.kill if reader.alive?
          reader.join
        end
      end
    rescue Errno::ENOENT
      raise Unavailable, 'Docker не установлен. Установите Docker и соберите образ проверки по docs/VERIFICATION.md.'
    end

    def flags(name)
      ['docker', 'run', '--rm', '--pull=never', '--name', name,
       '--network=none', '--read-only', '--cap-drop=ALL', '--log-driver=none',
       '--security-opt=no-new-privileges', '--user=65534:65534',
       '--memory=128m', '--memory-swap=128m', '--cpus=0.5',
       '--pids-limit=32', '--ulimit', 'nofile=64:64',
       '--tmpfs', '/tmp:rw,noexec,nosuid,size=8m']
    end

    def in_container(extra, seconds: 20)
      name = "paybridge-verify-#{SecureRandom.hex(12)}"
      begin
        capture(flags(name) + extra, seconds: seconds)
      ensure
        # The client dying does not stop the container. Explicit removal is
        # required on timeout, overflow, daemon error and successful completion.
        begin
          capture(['docker', 'rm', '-f', name], seconds: 3, limit: 8192)
        rescue Failure, Unavailable
          nil
        end
      end
    end

    def capability
      _, ok = in_container([IMAGE, 'ruby', '-e', 'exit 0'], seconds: 5)
      return { verification_available: true, verification_reason: nil } if ok

      { verification_available: false, verification_reason: 'Docker или образ проверки недоступен. Запустите Docker и выполните инструкции docs/VERIFICATION.md.' }
    rescue Failure, Unavailable => e
      { verification_available: false, verification_reason: e.message }
    end

    def run(directory, provider)
      raise Busy, 'Другая проверка уже выполняется. Повторите позже.' unless @lock.try_lock

      begin
        capability_result = capability
        raise Unavailable, capability_result[:verification_reason] unless capability_result[:verification_available]
        raise Failure, 'Некорректное имя провайдера.' unless provider.match?(/\A[a-z][a-z0-9_]{1,32}\z/)

        Dir.mktmpdir('paybridge-verification-') do |snapshot|
          # Mount only a private copy of required artifacts, never the project,
          # other integrations, credentials or Docker socket.
          File.chmod(0o755, snapshot)
          %W[base_service.rb #{provider}_service.rb fixtures.json].each do |name|
            source = File.join(directory, name)
            raise Failure, "Недоступен файл #{name}." unless File.file?(source) && !File.symlink?(source)
            raise Failure, 'Файлы проверки слишком большие.' if File.size(source) > MAX_INPUT

            destination = File.join(snapshot, name)
            FileUtils.cp(source, destination)
            File.chmod(0o644, destination)
          end
          mount = "type=bind,source=#{File.expand_path(snapshot)},target=/input,readonly"
          output, ok = in_container(['--mount', mount, IMAGE, 'ruby', '/runner/worker.rb'])
          raise Failure, 'Проверка аварийно завершилась. Проверьте сгенерированный код и fixtures.' unless ok

          parse_report(output)
        end
      ensure
        @lock.unlock
      end
    end

    def parse_report(output)
      report = JSON.parse(output)
      cases = report['cases']
      valid = cases.is_a?(Array) && !cases.empty? && cases.size <= 500 && cases.all? do |item|
        item.is_a?(Hash) && item['name'].is_a?(String) &&
          [true, false].include?(item['ok']) && item['detail'].is_a?(String)
      end
      raise Failure, 'Проверка вернула некорректный или пустой отчёт.' unless valid

      { passed: cases.count { |c| c['ok'] }, failed: cases.count { |c| !c['ok'] }, cases: cases }
    rescue JSON::ParserError, TypeError, NoMethodError
      raise Failure, 'Не удалось прочитать отчёт проверки.'
    end
  end
end
