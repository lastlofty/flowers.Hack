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
      return verify(argv[1..]) if argv.first == 'verify'
      return validate(argv[1..]) if argv.first == 'validate'

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

    # integrate validate --spec provider_api.yaml --provider <name>
    # Разбор без генерации: показать, что распознал парсер.
    def validate(argv)
      opts = { config: Paybridge::DEFAULT_CONFIG }
      OptionParser.new do |o|
        o.banner = 'Usage: integrate validate --spec <file> --provider <name>'
        o.on('--spec PATH') { |v| opts[:spec] = v }
        o.on('--provider NAME') { |v| opts[:provider] = v }
        o.on('--overrides PATH') { |v| opts[:overrides] = v }
        o.on('--config PATH') { |v| opts[:config] = v }
      end.parse!(argv)
      abort 'Не указан --spec' unless opts[:spec]
      abort 'Не указан --provider' unless opts[:provider]

      model = Paybridge.parse_only(
        spec_path: opts[:spec], provider: opts[:provider],
        config_path: opts[:config], overrides_path: opts[:overrides]
      )
      print_model(model)
      0
    rescue Paybridge::GenerationError => e
      warn "\e[31mОшибка разбора:\e[0m #{e.message}"
      1
    end

    def print_model(m)
      puts "Провайдер: #{m[:provider]} (#{m[:title]} v#{m[:version]})"
      puts "BASE_URL:  #{m[:base_url]}"
      puts "Методы (#{m[:endpoints].size}):"
      m[:endpoints].each { |e| puts "  #{e[:method].ljust(5)} #{e[:path]}  [#{e[:role]}]" }
      if m[:auth]
        puts "Авторизация: #{m[:auth][:type]} (#{m[:auth][:header]})"
      end
      puts "Idempotency: #{m[:idempotency_header]}" if m[:idempotency_header]
      puts 'Маппинг статусов:'
      m[:status_map].each { |p, i| puts "  #{p.ljust(12)} -> #{i}" }
      puts "Ошибки: #{m[:error_map].map { |k, v| "#{k}=#{v}" }.join(', ')}"
      if m[:webhook]
        w = m[:webhook]
        puts "Webhook: #{w[:path]} | события: #{w[:events].join(', ')}"
        puts "  подпись: #{w[:signature_header]} (HMAC-#{w[:signature_alg]})" if w[:signature_header]
      end
      return if m[:warnings].empty?

      puts "\e[33mПредупреждения (#{m[:warnings].size}):\e[0m"
      m[:warnings].each { |w| puts "  - #{w}" }
    end

    # integrate verify --dir output/
    def verify(argv)
      dir = './output'
      OptionParser.new do |o|
        o.banner = 'Usage: integrate verify --dir <output-dir>'
        o.on('--dir DIR', 'Каталог со сгенерированной интеграцией') { |v| dir = v }
      end.parse!(argv)

      report = Verifier.new(dir).run
      report.cases.each do |c|
        mark = c.ok ? "\e[32mOK  \e[0m" : "\e[31mFAIL\e[0m"
        line = "  #{mark} #{c.name}"
        line += " — #{c.detail}" unless c.ok
        puts line
      end
      puts
      puts "#{report.passed} passed, #{report.failed} failed"
      report.all_passed? ? 0 : 1
    rescue Verifier::LoadError => e
      warn "\e[31mОшибка загрузки интеграции:\e[0m #{e.message}"
      1
    end

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
        'test fixtures' => Generators::FixturesGenerator.new(spec, spec_source: source, config: config),
        'executable test' => Generators::TestGenerator.new(spec, spec_source: source, config: config)
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
