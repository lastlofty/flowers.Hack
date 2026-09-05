# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'open3'
require 'rbconfig'
require 'securerandom'
require 'stringio'
require 'time'

module Paybridge
  # Файловое хранилище с атомарными metadata.json и восстановлением индекса.
  class Store
    METADATA_FILE = 'metadata.json'
    DEFAULT_VERIFICATION = {
      'status' => 'not_run', 'passed' => 0, 'failed' => 0, 'skipped' => 0,
      'checked_at' => nil, 'cases' => []
    }.freeze

    Integration = Struct.new(
      :id, :provider, :status, :warnings, :files, :endpoints, :valid, :syntax_error,
      :created_at, :model, :verification, keyword_init: true
    )

    def initialize(root, logger: nil)
      @root = File.expand_path(root)
      @logger = logger
      @index = {}
      FileUtils.mkdir_p(@root)
      restore_index
    end

    def tmp_spec(content)
      dir = File.join(@root, 'tmp')
      FileUtils.mkdir_p(dir)
      path = File.join(dir, "spec_#{SecureRandom.hex(12)}.yaml")
      File.write(path, content, mode: 'wb')
      path
    end

    def save(generation)
      id, dir = create_integration_directory
      generation.files.each { |name, body| write_artifact(dir, name, body) }
      copy_base_service(dir)
      files = generation.files.keys.push('base_service.rb').uniq.sort
      valid, syntax_error = syntax_check(File.join(dir, "#{generation.provider}_service.rb"))

      integration = Integration.new(
        id: id, provider: generation.provider, status: 'generated',
        warnings: generation.warnings || [], files: files,
        endpoints: generation.endpoints || [], valid: valid, syntax_error: syntax_error,
        created_at: Time.now.utc.iso8601, model: generation.model || {},
        verification: deep_copy(DEFAULT_VERIFICATION)
      )
      persist(integration)
      @index[id] = integration
      integration
    rescue StandardError
      FileUtils.remove_entry(dir) if dir && Dir.exist?(dir)
      raise
    end

    def find(id) = @index[id.to_s]

    def list(page:, per_page:)
      sorted = @index.values.sort_by { |item| [item.created_at.to_s, item.id] }.reverse
      [sorted.slice((page - 1) * per_page, per_page) || [], sorted.length]
    end

    def file(integration, name)
      return nil unless safe_artifact_name?(name) && integration.files.include?(name)

      path = File.join(@root, integration.id, name)
      File.file?(path) ? File.binread(path) : nil
    end

    def directory(integration) = File.join(@root, integration.id)

    def model(integration) = deep_copy(integration.model || {})

    def save_verification(integration, verification)
      integration.verification = stringify_keys(verification)
      persist(integration)
      integration.verification
    end

    def archive(integration)
      require 'zip'
      dir = directory(integration)
      buffer = Zip::OutputStream.write_buffer do |archive|
        integration.files.sort.each do |name|
          next unless safe_artifact_name?(name)

          archive.put_next_entry(name)
          archive.write(File.binread(File.join(dir, name)))
        end
      end
      buffer.string
    end

    private

    def create_integration_directory
      loop do
        id = "int_#{SecureRandom.hex(12)}"
        dir = File.join(@root, id)
        begin
          # Контейнер проверки работает непривилегированным uid и читает этот
          # каталог через read-only bind mount.
          Dir.mkdir(dir, 0o755)
          return [id, dir]
        rescue Errno::EEXIST
          next
        end
      end
    end

    def write_artifact(dir, name, body)
      raise ArgumentError, "Недопустимое имя артефакта: #{name}" unless safe_artifact_name?(name)

      File.write(File.join(dir, name), body, mode: 'wb')
    end

    def safe_artifact_name?(name)
      value = name.to_s
      !value.empty? && value == File.basename(value) && !value.include?(File::SEPARATOR) && value != METADATA_FILE
    end

    def syntax_check(path)
      return [false, 'Сгенерированный сервис не найден'] unless File.file?(path)

      stdout = +''
      stderr = +''
      status = nil
      Open3.popen3(RbConfig.ruby, '-c', path, pgroup: true) do |stdin, out, err, wait|
        stdin.close
        readers = [bounded_reader(out, stdout), bounded_reader(err, stderr)]
        unless wait.join(5)
          terminate(wait.pid)
          readers.each(&:join)
          return [false, 'Проверка Ruby-синтаксиса превысила 5 секунд']
        end
        status = wait.value
        readers.each(&:join)
      end
      output = [stdout, stderr].reject(&:empty?).join("\n").strip
      [status.success?, status.success? ? nil : output]
    rescue StandardError => e
      [false, "Не удалось проверить Ruby-синтаксис: #{e.class}"]
    end

    def bounded_reader(io, target)
      Thread.new do
        while (chunk = io.read(4096))
          remaining = 64_000 - target.bytesize
          target << chunk.byteslice(0, remaining) if remaining.positive?
        end
      rescue IOError
        nil
      end
    end

    def terminate(pid)
      Process.kill('TERM', -pid)
      sleep 0.05
      Process.kill('KILL', -pid)
    rescue Errno::ESRCH
      nil
    end

    def copy_base_service(dir)
      base = File.expand_path('../lib/paybridge/templates/base_service.rb', __dir__)
      FileUtils.cp(base, File.join(dir, 'base_service.rb')) if File.file?(base)
    end

    def persist(integration)
      dir = directory(integration)
      temporary = File.join(dir, ".metadata.#{Process.pid}.#{SecureRandom.hex(4)}.tmp")
      File.open(temporary, 'wb', 0o600) do |file|
        file.write(JSON.pretty_generate(metadata_for(integration)))
        file.flush
        file.fsync
      end
      File.rename(temporary, File.join(dir, METADATA_FILE))
    ensure
      File.delete(temporary) if temporary && File.exist?(temporary)
    end

    def metadata_for(integration)
      {
        'schema_version' => 1, 'id' => integration.id, 'provider' => integration.provider,
        'status' => integration.status, 'warnings' => integration.warnings,
        'files' => integration.files, 'endpoints' => integration.endpoints,
        'valid' => integration.valid, 'syntax_error' => integration.syntax_error,
        'created_at' => integration.created_at, 'model' => integration.model,
        'verification' => integration.verification
      }
    end

    def restore_index
      Dir.glob(File.join(@root, 'int_*', METADATA_FILE)).each do |path|
        data = JSON.parse(File.read(path, 2_000_001))
        integration = restore_integration(data, File.dirname(path))
        @index[integration.id] = integration if integration
      rescue StandardError => e
        log("Не удалось восстановить #{path}: #{e.class}: #{e.message}")
      end
    end

    def restore_integration(data, dir)
      return unless data['status'] == 'generated'
      return unless data['id'].to_s.match?(/\Aint_[0-9a-f]{24}\z/)
      return unless File.basename(dir) == data['id']

      files = Array(data['files']).select { |name| safe_artifact_name?(name) }
      return unless files.all? { |name| File.file?(File.join(dir, name)) }

      Integration.new(
        id: data['id'], provider: data['provider'], status: data['status'], warnings: data['warnings'] || [],
        files: files, endpoints: data['endpoints'] || [], valid: data['valid'], syntax_error: data['syntax_error'],
        created_at: data['created_at'], model: data['model'] || {},
        verification: data['verification'] || deep_copy(DEFAULT_VERIFICATION)
      )
    end

    def stringify_keys(value)
      JSON.parse(JSON.generate(value))
    end

    def deep_copy(value) = JSON.parse(JSON.generate(value))

    def log(message)
      @logger ? @logger.warn(message) : warn(message)
    end
  end
end
