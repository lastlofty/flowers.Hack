# frozen_string_literal: true

require 'yaml'
require 'json'

require_relative 'paybridge/report'
require_relative 'paybridge/ir'
require_relative 'paybridge/spec_parser'
require_relative 'paybridge/generators/service_generator'
require_relative 'paybridge/generators/docs_generator'
require_relative 'paybridge/generators/fixtures_generator'
require_relative 'paybridge/cli'

# Единая точка входа PayBridge.
#
# Обслуживает три потребителя одним и тем же ядром:
#   * CLI            — exe/integrate  (Paybridge::CLI)
#   * веб-бэкенд     — app/api.rb     (Paybridge.generate)
#   * тесты          — test/*
module Paybridge
  ROOT           = File.expand_path('..', __dir__)
  DEFAULT_CONFIG = File.join(ROOT, 'config', 'mapping.yml')
  # Каркас платформы Space Payments — копируется рядом с результатом.
  BASE_SERVICE   = File.expand_path('paybridge/templates/base_service.rb', __dir__)

  # Результат генерации, который потребляет бэкенд.
  Generation = Struct.new(:provider, :files, :warnings, :endpoints, keyword_init: true)

  # Ошибка разбора/генерации — бэкенд оборачивает её в HTTP 422.
  class GenerationError < StandardError; end

  def self.load_config(path = DEFAULT_CONFIG)
    YAML.safe_load(File.read(path))
  rescue Errno::ENOENT
    raise GenerationError, "Файл конфигурации не найден: #{path}"
  end

  # Опциональный overrides-файл: уточняет то, что нельзя достать из структуры
  # OpenAPI (amount_unit, signature_encoding, required_if). Отсутствие — это {}.
  def self.load_overrides(path = nil)
    return {} if path.nil?

    YAML.safe_load(File.read(path)) || {}
  rescue Errno::ENOENT
    raise GenerationError, "Файл overrides не найден: #{path}"
  end

  # Главный фасад: спецификация -> { имя_файла => содержимое }.
  def self.generate(spec_path:, provider:, config_path: DEFAULT_CONFIG, overrides_path: nil)
    config    = load_config(config_path)
    overrides = load_overrides(overrides_path)
    spec      = SpecParser.new(spec_path, provider, config, overrides).parse
    source    = File.basename(spec_path)

    files = {
      "#{provider}_service.rb" =>
        Generators::ServiceGenerator.new(spec, spec_source: source, config: config).render,
      'INTEGRATION.md' =>
        Generators::DocsGenerator.new(spec, spec_source: source, config: config).render,
      'fixtures.json' =>
        Generators::FixturesGenerator.new(spec, spec_source: source, config: config).render
    }

    Generation.new(
      provider: provider,
      files: files,
      warnings: spec.report.warnings,
      endpoints: spec.endpoints.map do |e|
        { method: e.http_method.upcase, path: e.path, role: e.role.to_s }
      end
    )
  rescue SpecParser::ParseError => e
    raise GenerationError, e.message
  end

  # Dry-run: только разбор спецификации, без генерации файлов.
  # Для эндпоинта POST /api/validate (превью «что распознано»).
  def self.parse_only(spec_path:, provider:, config_path: DEFAULT_CONFIG, overrides_path: nil)
    config    = load_config(config_path)
    overrides = load_overrides(overrides_path)
    spec      = SpecParser.new(spec_path, provider, config, overrides).parse

    {
      provider: provider,
      title: spec.title,
      version: spec.version,
      base_url: spec.base_url,
      endpoints: spec.endpoints.map do |e|
        { method: e.http_method.upcase, path: e.path, role: e.role.to_s }
      end,
      auth: spec.auth && {
        type: spec.auth.scheme_type,
        header: spec.auth.header_name,
        credentials_field: spec.auth.credentials_field
      },
      idempotency_header: spec.idempotency_header,
      status_map: spec.status_map,
      error_map: spec.error_map,
      webhook: spec.webhook && {
        path: spec.webhook.path,
        events: spec.webhook.events,
        signature_header: spec.webhook.signature_header,
        signature_alg: spec.webhook.signature_alg
      },
      warnings: spec.report.warnings
    }
  rescue SpecParser::ParseError => e
    raise GenerationError, e.message
  end
end
