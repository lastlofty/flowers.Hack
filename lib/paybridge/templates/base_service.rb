# frozen_string_literal: true

# Каркас платформы Space Payments. Предоставляется платформой, генератором
# НЕ создаётся — копируется рядом со сгенерированным сервисом, чтобы результат
# был самодостаточным и проверяемым.
module Provider
  class Error < StandardError; end
  class RateLimitError < Error; end
  class UnauthorizedError < Error; end
  class NetworkError < Error; end

  Result = Struct.new(:status, :code, :message, :data, keyword_init: true) do
    def success?
      status == :success
    end

    def failed?
      !success?
    end
  end

  class BaseService
    attr_reader :provider

    def initialize(provider:)
      @provider = provider
    end

    def check_conditions(_operation, _request_method)
      success
    end

    def create_request(_operation, _request_method = 'create')
      raise NotImplementedError
    end

    def fetch_status(_operation)
      raise NotImplementedError
    end

    def process_callback(_raw_body, _signature = nil, _headers = {})
      raise NotImplementedError
    end

    private

    def success(data = nil)
      Result.new(status: :success, code: :ok, message: nil, data: data)
    end

    def failure(code, message, data: nil)
      Result.new(status: :failed, code: code, message: message, data: data)
    end

    def client
      @client ||= HttpClient.new
    end
  end

  # Тонкая обёртка над net/http (stdlib).
  class HttpClient
    require 'net/http'
    require 'json'
    require 'openssl'
    require 'socket'
    require 'timeout'
    require 'uri'

    Response = Struct.new(:status, :body, keyword_init: true)

    def initialize(
      open_timeout: ENV.fetch('PAYBRIDGE_HTTP_OPEN_TIMEOUT', '3'),
      read_timeout: ENV.fetch('PAYBRIDGE_HTTP_READ_TIMEOUT', '10'),
      write_timeout: ENV.fetch('PAYBRIDGE_HTTP_WRITE_TIMEOUT', '10')
    )
      @open_timeout = positive_timeout(open_timeout, 'open_timeout')
      @read_timeout = positive_timeout(read_timeout, 'read_timeout')
      @write_timeout = positive_timeout(write_timeout, 'write_timeout')
    end

    def post(url, json:, headers: {})
      request(:post, url, json: json, headers: headers)
    end

    def get(url, headers: {})
      request(:get, url, headers: headers)
    end

    private

    def request(method, url, json: nil, headers: {})
      uri = URI.parse(url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == 'https')
      http.open_timeout = @open_timeout
      http.read_timeout = @read_timeout
      http.write_timeout = @write_timeout

      req = build_request(method, uri)
      headers.each { |k, v| req[k] = v }
      if json
        req['Content-Type'] = 'application/json'
        req.body = JSON.generate(json)
      end

      raw = http.request(req)
      Response.new(status: raw.code.to_i, body: parse_body(raw.body))
    rescue Timeout::Error, SocketError, SystemCallError, IOError, EOFError,
           Net::ProtocolError, OpenSSL::SSL::SSLError => e
      raise NetworkError, "provider request failed: #{e.class}"
    end

    def build_request(method, uri)
      case method
      when :post then Net::HTTP::Post.new(uri)
      when :get  then Net::HTTP::Get.new(uri)
      else raise ArgumentError, "unsupported method: #{method}"
      end
    end

    def parse_body(body)
      return {} if body.nil? || body.empty?

      JSON.parse(body)
    rescue JSON::ParserError
      {}
    end

    def positive_timeout(value, name)
      timeout = Float(value)
      raise ArgumentError, "#{name} must be positive" unless timeout.positive? && timeout.finite?

      timeout
    rescue TypeError, ArgumentError
      raise ArgumentError, "#{name} must be a positive number"
    end
  end
end
