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
      return lint_cmd(argv[1..]) if argv.first == 'lint'
      return diff_cmd(argv[1..]) if argv.first == 'diff'

      options = parse_options(argv)
      run(options)
    rescue SpecParser::ParseError => e
      warn "\e[31mОшибка разбора спецификации:\e[0m #{e.message}"
      1
    rescue StandardError => e
      warn "\e[31mОшибка генерации:\e[0m #{e.message}"
      1
    end

    private

    # integrate lint --spec provider_api.yaml
    # Структурная проверка OpenAPI Python-модулем (tools/openapi_lint.py).
    def lint_cmd(argv)
      spec = nil
      OptionParser.new do |o|
        o.banner = 'Usage: integrate lint --spec <file|url>'
        o.on('--spec PATH') { |v| spec = v }
      end.parse!(argv)
      abort 'Не указан --spec' unless spec

      require 'yaml'
      content = if spec.match?(%r{\Ahttps?://}i)
                  require 'open-uri'
                  URI.parse(spec).open(&:read)
                else
                  File.read(spec)
                end
      doc = YAML.safe_load(content, aliases: true)

      report = Paybridge::Linter.lint(doc)
      if report['skipped']
        warn "\e[33mЛинтер пропущен:\e[0m #{report['reason']} (Python-модуль опционален)"
        return 0
      end
      if report['error']
        warn "\e[31mЛинтер не отработал:\e[0m #{report['reason']}"
        return 1
      end

      (report['warnings'] || []).each { |w| puts "\e[33mwarn\e[0m  #{w['path']}: #{w['message']}" }
      (report['errors'] || []).each  { |e| puts "\e[31merror\e[0m #{e['path']}: #{e['message']}" }
      if report['valid']
        puts "\e[32mOK\e[0m — структура OpenAPI валидна"
        0
      else
        puts "Найдено ошибок: #{report['errors'].size}"
        1
      end
    rescue StandardError => e
      warn "\e[31mОшибка линта:\e[0m #{e.message}"
      1
    end

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

      report = VerificationRunner.new(timeout: ENV.fetch('PAYBRIDGE_VERIFY_TIMEOUT', '10')).run(dir)
      report.cases.each do |c|
        mark = case c.status
               when 'passed' then "\e[32mOK  \e[0m"
               when 'skipped' then "\e[33mSKIP\e[0m"
               else "\e[31mFAIL\e[0m"
               end
        line = "  #{mark} #{c.name}"
        line += " — #{c.detail}" unless c.status == 'passed'
        puts line
      end
      puts
      puts "#{report.passed} passed, #{report.failed} failed, #{report.skipped} skipped"
      report.failed.zero? ? 0 : 1
    rescue VerificationRunner::Unavailable, VerificationRunner::TimedOut, VerificationRunner::ExecutionError => e
      warn "\e[31mПроверка недоступна:\e[0m #{e.message}"
      1
    end

    # integrate diff --spec provider_api.yaml --provider novapay --dir output/
    # Перегенерирует в память и сверяет байт-в-байт с уже сгенерированным каталогом.
    # Ненулевой код при расхождении — детерминизм в CI без внешних инструментов.
    def diff_cmd(argv)
      opts = { dir: './output', config: Paybridge::DEFAULT_CONFIG }
      OptionParser.new do |o|
        o.banner = 'Usage: integrate diff --spec <file|url> --provider <name> --dir <output>'
        o.on('--spec PATH') { |v| opts[:spec] = v }
        o.on('--provider NAME') { |v| opts[:provider] = v }
        o.on('--dir DIR', 'Каталог ранее сгенерированной интеграции') { |v| opts[:dir] = v }
        o.on('--overrides PATH') { |v| opts[:overrides] = v }
        o.on('--config PATH') { |v| opts[:config] = v }
      end.parse!(argv)
      abort 'Не указан --spec' unless opts[:spec]
      abort 'Не указан --provider' unless opts[:provider]

      gen = Paybridge.generate(
        spec_path: opts[:spec], provider: opts[:provider],
        config_path: opts[:config], overrides_path: opts[:overrides]
      )

      drift = gen.files.filter_map do |name, body|
        path = File.join(opts[:dir], name)
        next "\e[33m+ #{name}\e[0m (отсутствует в #{opts[:dir]})" unless File.file?(path)
        next "\e[31m~ #{name}\e[0m (отличается)" if File.binread(path) != body.b

        nil
      end

      if drift.empty?
        puts "\e[32mdiff: без изменений\e[0m — генерация детерминирована и совпадает с #{opts[:dir]}"
        0
      else
        drift.each { |line| puts "  #{line}" }
        puts "diff: расхождений — #{drift.size}. Перегенерируйте (`integrate --spec … --provider …`)."
        1
      end
    rescue Paybridge::GenerationError => e
      warn "\e[31mОшибка генерации:\e[0m #{e.message}"
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
        o.on('--strict', 'Ненулевой код выхода, если есть поля для ручного заполнения') { options[:strict] = true }
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
        'executable test' => Generators::TestGenerator.new(spec, spec_source: source, config: config),
        'decisions map' => Generators::MappingGenerator.new(spec, spec_source: source, config: config),
        'postman collection' => Generators::PostmanGenerator.new(spec, spec_source: source, config: config)
      }

      written = []
      generators.each do |label, generator|
        say "Generating #{label}..."
        path = File.join(options[:output], generator.filename)
        # binwrite: байт-в-байт (LF), без CRLF-трансляции на Windows — вывод
        # детерминирован на всех платформах и сходится с `integrate diff`/golden.
        File.binwrite(path, generator.render)
        written << path
      end

      # каркас платформы копируется рядом, чтобы сервис был запускаемым
      base_path = File.join(options[:output], 'base_service.rb')
      FileUtils.cp(Paybridge::BASE_SERVICE, base_path)
      written << base_path

      print_result(written, spec)

      # --strict: незакрытые поля для ручного заполнения -> ненулевой код (для CI).
      if options[:strict] && spec.report.todos?
        warn "\e[31m--strict:\e[0m #{spec.report.todos.size} поле(й) требуют ручного заполнения — сборка не считается завершённой"
        return 1
      end
      0
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

      print_manual_todos(spec)

      return unless spec.report.any?

      puts
      puts "\e[33mПредупреждения (#{spec.report.warnings.size}):\e[0m"
      spec.report.each { |w| puts "  - #{w}" }
    end

    # Поля, которые нельзя вывести из спеки — их заполняет разработчик вручную.
    # Показываем отдельным заметным блоком с подсказкой и местом в коде.
    def print_manual_todos(spec)
      return unless spec.report.todos?

      puts
      puts "\e[31m❗ Заполните вручную (#{spec.report.todos.size}):\e[0m " \
           'в сгенерированном коде эти поля помечены комментарием TODO(PayBridge)'
      spec.report.todos.each do |todo|
        puts "  • \e[1m#{todo.field}\e[0m (#{todo.where})"
        puts "      #{todo.hint}"
      end
    end

    def say(message)
      puts message
    end
  end
end
