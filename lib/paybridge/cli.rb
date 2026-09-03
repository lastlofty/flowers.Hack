# frozen_string_literal: true

require 'optparse'
require 'fileutils'

module Paybridge
  # Командная строка генератора: разбирает аргументы, запускает парсер и
  # генераторы, печатает понятный пошаговый вывод и обрабатывает ошибки.
  class CLI
    def self.start(argv)
      new.start(argv)
    end

    def start(argv)
      options = parse_options(argv)
      run(options)
      0
    rescue SpecParser::ParseError => e
      warn "\e[31mОшибка разбора спецификации:\e[0m #{e.message}"
      1
    rescue StandardError => e
      warn "\e[31mОшибка генерации:\e[0m #{e.message}"
      1
    end

    private

    def parse_options(argv)
      options = { output: './output', lang: 'ruby', config: Paybridge::DEFAULT_CONFIG }
      parser = OptionParser.new do |o|
        o.banner = 'Usage: integrate --spec provider_api.yaml --provider <name> [options]'
        o.on('--spec PATH', 'Путь к OpenAPI-спецификации') { |v| options[:spec] = v }
        o.on('--provider NAME', 'Имя провайдера (напр. novapay)') { |v| options[:provider] = v }
        o.on('--output DIR', 'Каталог для результатов (по умолчанию ./output)') { |v| options[:output] = v }
        o.on('--config PATH', 'Файл правил маппинга') { |v| options[:config] = v }
        o.on('--overrides PATH', 'Файл уточнений (amount_unit, signature_encoding, required_if)') { |v| options[:overrides] = v }
        o.on('--lang LANG', 'Язык генерации (поддерживается только ruby)') { |v| options[:lang] = v }
        o.on('-h', '--help', 'Показать справку') { puts o; exit 0 }
      end
      parser.parse!(argv)

      abort 'Не указан --spec' unless options[:spec]
      abort 'Не указан --provider' unless options[:provider]
      unless options[:lang] == 'ruby'
        warn "Язык '#{options[:lang]}' не поддерживается — генерирую Ruby."
        options[:lang] = 'ruby'
      end
      options
    end

    def run(options)
      config    = Paybridge.load_config(options[:config])
      overrides = Paybridge.load_overrides(options[:overrides])

      say 'Parsing spec...'
      spec = SpecParser.new(options[:spec], options[:provider], config, overrides).parse
      print_summary(spec)

      FileUtils.mkdir_p(options[:output])
      source = File.basename(options[:spec])

      generators = {
        'service' => Generators::ServiceGenerator.new(spec, spec_source: source, config: config),
        'integration guide' => Generators::DocsGenerator.new(spec, spec_source: source, config: config),
        'test fixtures' => Generators::FixturesGenerator.new(spec, spec_source: source, config: config)
      }

      written = []
      generators.each do |label, generator|
        say "Generating #{label}..."
        path = File.join(options[:output], generator.filename)
        File.write(path, generator.render)
        written << path
      end

      # каркас платформы копируется рядом, чтобы сервис был запускаемым
      base_path = File.join(options[:output], 'base_service.rb')
      FileUtils.cp(Paybridge::BASE_SERVICE, base_path)
      written << base_path

      print_result(written, spec)
    end

    def print_summary(spec)
      say "Found #{spec.endpoints.size} endpoints: #{spec.endpoints.map(&:to_s).join(', ')}"
      say "Auth: #{spec.auth.scheme_type} (header: #{spec.auth.header_name})" if spec.auth
      if spec.webhook && spec.webhook.signature_header
        say "Webhook signature: #{spec.webhook.signature_header} (HMAC-#{spec.webhook.signature_alg})"
      end
    end

    def print_result(written, spec)
      puts
      puts 'Output:'
      written.each { |path| puts "  #{path}" }

      return unless spec.report.any?

      puts
      puts "\e[33mПредупреждения (#{spec.report.warnings.size}):\e[0m"
      spec.report.each { |w| puts "  - #{w}" }
    end

    def say(message)
      puts message
    end
  end
end
