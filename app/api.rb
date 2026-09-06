# frozen_string_literal: true

require 'json'
require 'securerandom'
require 'sinatra/base'
require 'timeout'
require_relative 'store'
require_relative 'serializers'
require_relative '../lib/paybridge'

module Paybridge
  # HTTP-обёртка: ограничивает вход, время операций и изолирует verify.
  class API < Sinatra::Base
    MAX_SPEC_BYTES = 1_000_000
    MAX_OVERRIDES_BYTES = 20_000
    MAX_HTTP_BODY_BYTES = MAX_SPEC_BYTES + 65_536
    PROVIDER_RE = Paybridge::PROVIDER_RE

    configure do
      set :store, Store.new(File.expand_path('../storage', __dir__))
      set :verification_runner, VerificationRunner.new(timeout: ENV.fetch('PAYBRIDGE_VERIFY_TIMEOUT', '10'))
      set :generation_timeout, Float(ENV.fetch('PAYBRIDGE_GENERATION_TIMEOUT', '10'))
      set :show_exceptions, false
      set :raise_errors, false
      enable :static
      set :public_folder, File.expand_path('../public', __dir__)
      set :host_authorization, { permitted_hosts: [] }
    end

    before do
      @request_started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      supplied = env['HTTP_X_REQUEST_ID'].to_s
      @request_id = supplied.match?(/\A[A-Za-z0-9_-]{1,64}\z/) ? supplied : "req_#{SecureRandom.hex(12)}"
      headers['X-Request-ID'] = @request_id
      if request.content_length && request.content_length.to_i > MAX_HTTP_BODY_BYTES
        api_error!('too_large', 'HTTP body превышает допустимый размер', 413)
      end
    end

    after do
      duration = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - @request_started_at) * 1000).round
      log = { request_id: @request_id, method: request.request_method, path: request.path_info,
              status: response.status, duration_ms: duration }
      log.merge!(@log_context) if @log_context
      env['rack.logger']&.info(JSON.generate(log))
    rescue StandardError
      nil
    end

    helpers do
      def json_response(object, status_code = 200)
        content_type :json
        status status_code
        JSON.generate(object)
      end

      def api_error!(code, message, status_code)
        halt status_code, { 'Content-Type' => 'application/json', 'X-Request-ID' => @request_id },
             JSON.generate(error: { code: code, message: message }, request_id: @request_id)
      end

      def store = settings.store

      def read_spec_upload!
        file = params[:spec]
        provider = params[:provider].to_s
        api_error!('missing_spec', 'Файл spec обязателен', 400) unless file.is_a?(Hash) && file[:tempfile]
        unless provider.match?(PROVIDER_RE)
          api_error!('invalid_provider', 'provider должен соответствовать ^[a-z][a-z0-9_]{1,32}$', 400)
        end
        unless file[:filename].to_s.match?(/\.ya?ml\z/i)
          api_error!('invalid_type', 'Ожидается файл .yaml или .yml', 400)
        end

        content = read_limited(file[:tempfile], MAX_SPEC_BYTES)
        api_error!('too_large', 'Файл больше 1 МБ', 413) if content.nil?
        @log_context = { provider: provider, warning_count: 0 }
        [content, provider]
      end

      def read_overrides!
        raw = params[:overrides]
        return {} if raw.nil? || raw.to_s.strip.empty?

        if raw.to_s.bytesize > MAX_OVERRIDES_BYTES
          api_error!('overrides_too_large', 'Файл уточнений слишком большой', 413)
        end
        parsed = JSON.parse(raw.to_s)
        unless parsed.is_a?(Hash)
          api_error!('invalid_overrides', 'Уточнения должны быть JSON-объектом', 400)
        end

        parsed
      rescue JSON::ParserError
        api_error!('invalid_overrides', 'Уточнения должны быть валидным JSON', 400)
      end

      def read_limited(io, limit)
        io.rewind if io.respond_to?(:rewind)
        content = +''
        while (chunk = io.read([65_536, limit + 1 - content.bytesize].min))
          content << chunk
          return nil if content.bytesize > limit
        end
        content
      end

      def with_temp_spec(content)
        path = store.tmp_spec(content)
        yield path
      ensure
        File.delete(path) if path && File.exist?(path)
      end

      def within_generation_timeout(&block)
        Timeout.timeout(settings.generation_timeout, Timeout::Error, &block)
      end

      def integration!
        integration = store.find(params[:id])
        api_error!('not_found', 'Интеграция не найдена', 404) unless integration
        @log_context = { provider: integration.provider, integration_id: integration.id,
                         warning_count: integration.warnings.length }
        integration
      end

      def parse_positive_integer(value, default, name, maximum: nil)
        raw = value.nil? ? default.to_s : value.to_s
        unless raw.match?(/\A[1-9]\d*\z/)
          api_error!('invalid_pagination', "#{name} должен быть положительным целым числом", 400)
        end
        number = raw.to_i
        api_error!('invalid_pagination', "#{name} не должен превышать #{maximum}", 400) if maximum && number > maximum
        number
      end

      def persist_verification(integration, report)
        body = report.respond_to?(:to_h) ? report.to_h : report
        store.save_verification(integration, body)
        body
      end

      def failed_verification(status, message)
        { status: status, passed: 0, failed: 0, skipped: 0,
          checked_at: Time.now.utc.iso8601, cases: [], message: message }
      end
    end

    get '/' do
      index = File.join(settings.public_folder, 'index.html')
      halt 404, 'UI не установлен' unless File.file?(index)

      content_type :html
      File.read(index)
    end

    get '/api/health' do
      available = settings.verification_runner.available?
      reason = available ? nil : 'Docker-среда проверки не найдена. Генерация и скачивание файлов доступны.'
      json_response(status: 'ok', verification_available: available,
                    verification_reason: reason, request_id: @request_id)
    end

    post '/api/validate' do
      content, provider = read_spec_upload!
      overrides = read_overrides!
      model = within_generation_timeout do
        with_temp_spec(content) { |path| Paybridge.parse_only(spec_path: path, provider: provider, overrides: overrides) }
      end
      @log_context[:warning_count] = Array(model[:warnings]).length
      json_response(model.merge(request_id: @request_id))
    rescue Timeout::Error
      api_error!('generation_timeout', 'Разбор спецификации превысил 10 секунд', 504)
    rescue Paybridge::GenerationError => e
      api_error!('validation_failed', e.message, 422)
    end

    post '/api/integrations' do
      content, provider = read_spec_upload!
      overrides = read_overrides!
      generation = within_generation_timeout do
        with_temp_spec(content) { |path| Paybridge.generate(spec_path: path, provider: provider, overrides: overrides) }
      end
      integration = store.save(generation)
      @log_context.merge!(integration_id: integration.id, warning_count: integration.warnings.length)
      json_response(Serializers.integration(integration).merge(request_id: @request_id), 201)
    rescue Timeout::Error
      api_error!('generation_timeout', 'Генерация превысила 10 секунд', 504)
    rescue Paybridge::GenerationError => e
      api_error!('generation_failed', e.message, 422)
    end

    get '/api/integrations' do
      page = parse_positive_integer(params[:page], 1, 'page')
      per_page = parse_positive_integer(params[:per_page], 20, 'per_page', maximum: 100)
      items, total = store.list(page: page, per_page: per_page)
      json_response(items: items.map { |item| Serializers.integration(item) }, page: page,
                    per_page: per_page, total: total, request_id: @request_id)
    end

    get '/api/integrations/:id' do
      json_response(Serializers.integration(integration!).merge(request_id: @request_id))
    end

    get '/api/integrations/:id/model' do
      json_response(store.model(integration!).merge('request_id' => @request_id))
    end

    get '/api/integrations/:id/files/:name' do
      integration = integration!
      content = store.file(integration, params[:name])
      api_error!('not_found', 'Файл не найден', 404) unless content
      content_type 'text/plain; charset=utf-8'
      headers['Content-Disposition'] = %(attachment; filename="#{params[:name]}")
      content
    end

    get '/api/integrations/:id/archive' do
      integration = integration!
      content_type 'application/zip'
      headers['Content-Disposition'] = %(attachment; filename="integration_#{integration.provider}.zip")
      store.archive(integration)
    end

    post '/api/integrations/:id/verify' do
      integration = integration!
      report = settings.verification_runner.run(store.directory(integration))
      body = persist_verification(integration, Serializers.verification(report))
      json_response(body.merge(request_id: @request_id))
    rescue VerificationRunner::Unavailable => e
      persist_verification(integration, failed_verification('unavailable', e.message)) if integration
      api_error!('verification_unavailable', 'Безопасная среда проверки недоступна', 503)
    rescue VerificationRunner::TimedOut
      persist_verification(integration, failed_verification('error', 'Проверка прервана по timeout')) if integration
      api_error!('verification_timeout', 'Проверка превысила ограничение времени', 504)
    rescue VerificationRunner::ExecutionError
      persist_verification(integration, failed_verification('error', 'Проверку не удалось выполнить')) if integration
      api_error!('verification_failed', 'Некорректный артефакт или ошибка среды проверки', 422)
    end

    error do
      exception = env['sinatra.error']
      env['rack.logger']&.error(
        JSON.generate(request_id: @request_id, error_class: exception&.class&.name,
                      message: exception&.message.to_s.slice(0, 300))
      )
      json_response({ error: { code: 'internal_error', message: 'Внутренняя ошибка' }, request_id: @request_id }, 500)
    end

    not_found do
      json_response({ error: { code: 'not_found', message: 'Маршрут не найден' }, request_id: @request_id }, 404)
    end
  end
end
