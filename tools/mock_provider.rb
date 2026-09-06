# frozen_string_literal: true

require 'webrick'
require 'json'
require 'openssl'
require 'base64'

module Paybridge
  # Мок платёжного провайдера на WEBrick: поднимает create/status-эндпоинты из
  # распарсенной спеки и отвечает как настоящий провайдер. Сгенерированный сервис
  # ходит сюда РЕАЛЬНЫМ net/http (BASE_URL указывает на этот сервер).
  # Также умеет слать подписанный webhook — для сквозной проверки.
  class MockProvider
    attr_reader :requests

    def initialize(spec, created_status:, final_status:)
      @spec = spec
      @created = created_status
      @final = final_status
      @requests = []
      @server = WEBrick::HTTPServer.new(
        Port: 0, BindAddress: '127.0.0.1',
        Logger: WEBrick::Log.new(File::NULL, WEBrick::BasicLog::FATAL), AccessLog: []
      )
      @server.mount_proc('/') { |req, res| handle(req, res) }
    end

    def port
      @server.listeners.first.addr[1]
    end

    def base_url
      "http://127.0.0.1:#{port}"
    end

    def start
      @thread = Thread.new { @server.start }
      sleep 0.05
      self
    end

    def stop
      @server.shutdown
      @thread&.join
    end

    # Webhook как отправил бы провайдер: [raw_body (строка), signature].
    # Контракт process_callback(raw_body, signature) — подпись по СЫРЫМ байтам.
    def webhook_message(payload, secret: 'test_secret')
      wh = @spec.webhook
      raw = JSON.generate(payload)
      sig = if wh&.signature_encoding == 'base64'
              Base64.strict_encode64(OpenSSL::HMAC.digest(wh.signature_alg, secret, raw))
            else
              OpenSSL::HMAC.hexdigest(wh&.signature_alg || 'SHA256', secret, raw)
            end
      [raw, sig]
    end

    private

    def handle(req, res)
      @requests << {
        method: req.request_method, path: req.path,
        auth: req['Authorization'] || req['X-API-Key'] || req['X-Api-Token'],
        idempotency: req['Idempotency-Key'], body: req.body
      }
      res['Content-Type'] = 'application/json'

      if req.request_method == 'POST' && req.path == @spec.create_endpoint.path
        res.status = 201
        res.body = JSON.generate('id' => 'srv_1', 'status' => @created)
      elsif req.request_method == 'GET' && status_request?(req)
        res.status = 200
        res.body = JSON.generate('id' => 'srv_1', 'status' => @final)
      else
        res.status = 404
        res.body = '{}'
      end
    end

    def status_request?(req)
      return false unless @spec.status_endpoint

      prefix = @spec.status_endpoint.path.sub(/\{[^}]+\}.*\z/, '')
      req.path.start_with?(prefix)
    end
  end
end
