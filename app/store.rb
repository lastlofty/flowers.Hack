# frozen_string_literal: true

require 'fileutils'
require 'securerandom'
require 'time'
require 'stringio'
require 'open3'
require 'rbconfig'

module Paybridge
  # Хранилище интеграций: метаданные — в памяти, файлы результата — в storage/<id>/.
  # Для хакатона достаточно; при желании заменяется на SQLite без смены интерфейса.
  class Store
    Integration = Struct.new(
      :id, :provider, :status, :warnings, :files, :endpoints, :valid, :syntax_error, :created_at,
      keyword_init: true
    )

    def initialize(root)
      @root = root
      @index = {}
      FileUtils.mkdir_p(@root)
    end

    # Пишет присланную спецификацию во временный файл, возвращает путь.
    def tmp_spec(content)
      dir = File.join(@root, 'tmp')
      FileUtils.mkdir_p(dir)
      path = File.join(dir, "spec_#{SecureRandom.hex(4)}.yaml")
      File.write(path, content)
      path
    end

    # Сохраняет результат генерации, возвращает Integration.
    def save(generation)
      id  = "int_#{SecureRandom.hex(4)}"
      dir = File.join(@root, id)
      FileUtils.mkdir_p(dir)

      generation.files.each { |name, body| File.write(File.join(dir, name), body) }
      copy_base_service(dir)
      valid, syntax_error = syntax_check(File.join(dir, "#{generation.provider}_service.rb"))

      integration = Integration.new(
        id: id,
        provider: generation.provider,
        status: 'generated',
        warnings: generation.warnings || [],
        files: Dir.children(dir).sort,
        endpoints: generation.endpoints || [],
        valid: valid,
        syntax_error: syntax_error,
        created_at: Time.now.utc.iso8601
      )
      @index[id] = integration
      integration
    end

    def find(id)
      @index[id]
    end

    def file(integration, name)
      return nil unless integration.files.include?(name)

      path = File.join(@root, integration.id, name)
      File.exist?(path) ? File.read(path) : nil
    end

    def directory(integration)
      File.join(@root, integration.id)
    end

    # Zip со всеми файлами интеграции; возвращает бинарную строку.
    def archive(integration)
      require 'zip'
      dir = File.join(@root, integration.id)
      buffer = Zip::OutputStream.write_buffer do |zos|
        Dir.children(dir).sort.each do |name|
          zos.put_next_entry(name)
          zos.write(File.read(File.join(dir, name)))
        end
      end
      buffer.string
    end

    private

    def syntax_check(path)
      return [false, 'Сгенерированный сервис не найден'] unless File.exist?(path)

      stdout, stderr, status = Open3.capture3(RbConfig.ruby, '-c', path)
      output = [stdout, stderr].reject(&:empty?).join("\n").strip
      [status.success?, status.success? ? nil : output]
    rescue StandardError => e
      [false, "Не удалось запустить ruby -c: #{e.message}"]
    end

    # Кладём рядом каркас платформы, чтобы результат был запускаемым.
    def copy_base_service(dir)
      base = File.expand_path('../lib/paybridge/templates/base_service.rb', __dir__)
      FileUtils.cp(base, File.join(dir, 'base_service.rb')) if File.exist?(base)
    end
  end
end
