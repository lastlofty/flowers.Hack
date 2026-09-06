# frozen_string_literal: true

require 'open3'
require 'json'

module Paybridge
  # Обёртка над Python-линтером (tools/openapi_lint.py). Многоязычность разрешена:
  # ядро — Ruby, структурная проверка OpenAPI вынесена в отдельный Python-модуль.
  # Модуль опционален: если Python недоступен, линт пропускается, генерация работает.
  module Linter
    module_function

    SCRIPT = File.expand_path('../../tools/openapi_lint.py', __dir__)

    def python_bin
      %w[python3 python].find do |bin|
        _out, _err, status = Open3.capture3(bin, '--version')
        status.success?
      rescue Errno::ENOENT
        false
      end
    end

    def available?
      !python_bin.nil? && File.exist?(SCRIPT)
    end

    # spec — распарсенный Hash (Ruby разбирает YAML, Python валидирует структуру).
    # Возвращает { 'valid'=>, 'errors'=>[], 'warnings'=>[] } или { 'skipped'=>true }.
    def lint(spec)
      bin = python_bin
      return { 'skipped' => true, 'reason' => 'Python недоступен' } unless bin && File.exist?(SCRIPT)

      out, err, = Open3.capture3(bin, SCRIPT, stdin_data: JSON.generate(spec))
      return { 'skipped' => true, 'reason' => err.strip } if out.strip.empty?

      JSON.parse(out)
    rescue StandardError => e
      { 'skipped' => true, 'reason' => e.message }
    end
  end
end
