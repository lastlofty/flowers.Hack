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
    # Возвращает один из трёх видов результата:
    #   { 'valid'=>, 'errors'=>[], 'warnings'=>[] } — линт отработал;
    #   { 'skipped'=>true, 'reason'=> } — Python недоступен (модуль опционален);
    #   { 'error'=>true, 'reason'=> } — Python ЕСТЬ, но вызов не удался.
    # Разделение важно: раньше реальный сбой (напр. кривая кодировка вывода) молча
    # попадал в 'skipped', и линтер незаметно отключался вместо явной ошибки.
    def lint(spec)
      bin = python_bin
      return { 'skipped' => true, 'reason' => 'Python недоступен' } unless bin && File.exist?(SCRIPT)

      out, err, = Open3.capture3(bin, SCRIPT, stdin_data: JSON.generate(spec))
      return { 'error' => true, 'reason' => "линтер не вернул результат: #{err.to_s.scrub.strip}" } if out.strip.empty?

      JSON.parse(out)
    rescue StandardError => e
      { 'error' => true, 'reason' => e.message.to_s.scrub }
    end
  end
end
