# frozen_string_literal: true

require 'sinatra/base'
require 'json'
require_relative 'store'
require_relative 'serializers'
require_relative '../lib/paybridge'

module Paybridge
  # HTTP-обёртка над генератором. Все провайдер-зависимые решения — в ядре;
  # здесь только приём файла, вызов Paybridge.generate и отдача результата.
  class API < Sinatra::Base
    MAX_SPEC_BYTES = 1_000_000
    PROVIDER_RE    = /\A[a-z][a-z0-9_]{1,32}\z/.freeze

    configure do
      set :store, Store.new(File.expand_path('../storage', __dir__))
      set :show_exceptions, false
      set :raise_errors, false
      enable :static
      set :public_folder, File.expand_path('../public', __dir__)
    end

    helpers do
      def json_response(obj, status_code = 200)
        content_type :json
        status status_code
        JSON.generate(obj)
      end

      def error!(code, message, status_code)
        halt status_code,
             { 'Content-Type' => 'application/json' },
             JSON.generate(error: { code: code, message: message })
      end

      def store
        settings.store
      end
    end

    # --- UI --------------------------------------------------------------
    get '/' do
      index = File.join(settings.public_folder, 'index.html')
      halt 404, 'UI не установлен' unless File.exist?(index)

      content_type :html
      File.read(index)
    end

    # --- health ----------------------------------------------------------
    get '/api/health' do
      json_response(status: 'ok')
    end

    # --- создание интеграции --------------------------------------------
    post '/api/integrations' do
      file     = params[:spec]
      provider = params[:provider].to_s

      error!('missing_spec', 'Файл spec обязателен', 400) unless file.is_a?(Hash) && file[:tempfile]
      error!('invalid_provider', 'provider должен соответствовать ^[a-z][a-z0-9_]{1,32}$', 400) unless provider.match?(PROVIDER_RE)
      error!('invalid_type', 'Ожидается файл .yaml или .yml', 400) unless file[:filename].to_s.match?(/\.ya?ml\z/i)

      content = file[:tempfile].read
      error!('too_large', 'Файл больше 1 МБ', 413) if content.bytesize > MAX_SPEC_BYTES

      spec_path = store.tmp_spec(content)
      begin
        generation = Paybridge.generate(spec_path: spec_path, provider: provider)
      rescue Paybridge::GenerationError => e
        error!('generation_failed', e.message, 422)
      ensure
        File.delete(spec_path) if spec_path && File.exist?(spec_path)
      end

      integration = store.save(generation)
      json_response(Serializers.integration(integration), 201)
    end

    # --- чтение метаданных ----------------------------------------------
    get '/api/integrations/:id' do
      integration = store.find(params[:id]) || error!('not_found', 'Интеграция не найдена', 404)
      json_response(Serializers.integration(integration))
    end

    # --- скачивание одного файла ----------------------------------------
    get '/api/integrations/:id/files/:name' do
      integration = store.find(params[:id]) || error!('not_found', 'Интеграция не найдена', 404)
      content = store.file(integration, params[:name]) || error!('not_found', 'Файл не найден', 404)

      content_type 'text/plain; charset=utf-8'
      headers['Content-Disposition'] = %(attachment; filename="#{params[:name]}")
      content
    end

    # --- скачивание zip --------------------------------------------------
    get '/api/integrations/:id/archive' do
      integration = store.find(params[:id]) || error!('not_found', 'Интеграция не найдена', 404)

      content_type 'application/zip'
      headers['Content-Disposition'] = %(attachment; filename="integration_#{integration.provider}.zip")
      store.archive(integration)
    end

    # --- на всё непойманное ---------------------------------------------
    error do
      json_response({ error: { code: 'internal_error', message: env['sinatra.error']&.message || 'internal error' } }, 500)
    end

    not_found do
      json_response({ error: { code: 'not_found', message: 'Маршрут не найден' } }, 404)
    end
  end
end
