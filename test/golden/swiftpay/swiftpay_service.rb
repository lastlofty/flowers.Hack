# frozen_string_literal: true

require 'openssl'
require 'json'
require 'bigdecimal'

# ────────────────────────────────────────────────────────────────────────
# СГЕНЕРИРОВАНО PayBridge 1.0.0 из swiftpay_api.yaml
# Провайдер: swiftpay (SwiftPay API v1.0.0)
# spec sha256: d4d9a3ec1715ef3bb3653fc9dec496cafb4d48e60daf67e3723a4bec2655d745
# Не редактировать вручную — вывод детерминирован по спеке; изменения перезапишутся.
# ────────────────────────────────────────────────────────────────────────
module Provider
  class SwiftpayService < BaseService
    BASE_URL = ENV.fetch('SWIFTPAY_BASE_URL', 'https://sandbox.swiftpay.example/v1')
    MIN_AMOUNT = 100

    STATUS_MAP = {
      'pending' => 'in_progress',
      'completed' => 'approved',
      'failed' => 'rejected'
    }.freeze

    ERROR_MAP = {
      401 => 'invalid_credentials',
      404 => 'not_found',
      422 => 'validation_error',
      500 => 'internal_error'
    }.freeze

    HTTP_STATUS_SYMBOL = {
      401 => :unauthorized,
      404 => :not_found,
      422 => :unprocessable_entity,
      500 => :internal_server_error
    }.freeze

    def check_conditions(operation, request_method)
      base_result = super
      return base_result if base_result.failed?
      return failure(:unprocessable_entity, 'amount_too_low') if amount_in_minor_units(operation.amount) < MIN_AMOUNT
      success
    end

    def create_request(operation, request_method = 'create')
      payload  = build_request_payload(operation, request_method)
      response = client.post(
        "#{BASE_URL}/payments",
        json: payload,
        headers: auth_headers
      )
      parse_create_response(operation, response)
    rescue Provider::RateLimitError
      failure(:too_many_requests, 'provider.rate_limit')
    rescue Provider::UnauthorizedError
      failure(:unauthorized, 'provider.invalid_credentials')
    rescue Provider::NetworkError
      failure(:service_unavailable, 'provider.network_error')
    end

    def fetch_status(operation)
      response = client.get(
        "#{BASE_URL}/payments/#{operation.provider_operation_id}",
        headers: auth_headers
      )
      return map_error(response) if response.status >= 400

      body = response.body.is_a?(Hash) ? response.body : {}
      mapped = map_status(body['status'])
      return failure(:unprocessable_entity, 'unknown_status') if mapped.nil?

      success(status: mapped)
    rescue Provider::NetworkError
      failure(:service_unavailable, 'provider.network_error')
    end

    private

    # Contract: amount is in major units, two decimal places per currency.
    # Decimal conversion avoids binary Float truncation; ties round half up.
    # The same conversion is used for validation and the outgoing request.
    def amount_in_minor_units(value)
      decimal = BigDecimal(value.to_s)
      raise ArgumentError, 'amount must be finite' unless decimal.finite?

      (decimal * 100).round(0, BigDecimal::ROUND_HALF_UP).to_i
    end

    def build_request_payload(operation, request_method = nil)
      requisite = operation.payout_requisite || {}
      {
        amount: amount_in_minor_units(operation.amount),
        currency: 'USD',
        reference: operation.id.to_s
      }
    end

    def parse_create_response(_operation, response)
      case response.status
      when 201
        parse_success_response(response)
      else
        map_error(response)
      end
    end

    def parse_success_response(response)
      body   = response.body.is_a?(Hash) ? response.body : {}
      id     = body['id']
      status = map_status(body['status'])
      if id.nil? || status.nil?
        # id/status отсутствуют или статус неизвестен — не выдаём success с nil
        failure(:unprocessable_entity, 'incomplete_response',
                data: { id: id, provider_status: body['status'] })
      else
        success(provider_operation_id: id, status: status)
      end
    end

    def map_status(provider_status)
      STATUS_MAP[provider_status]
    end

    def map_error(response)
      code    = ERROR_MAP[response.status] || 'internal_error'
      message = response.body.is_a?(Hash) ? response.body.dig('error', 'message') : nil
      failure(error_symbol(response.status), code, data: { message: message || 'provider_error' })
    end

    def error_symbol(http_status)
      HTTP_STATUS_SYMBOL.fetch(http_status, :internal_server_error)
    end

    def auth_headers
      { 'Authorization' => "Bearer #{provider.credentials.fetch('token')}" }
    end

    def approve_operation(provider_operation_id, mapped_status)
      success(provider_operation_id: provider_operation_id, status: mapped_status || 'approved')
    end

    def reject_operation(provider_operation_id, error_code)
      failure(:rejected, error_code || 'rejected', data: { provider_operation_id: provider_operation_id })
    end
  end
end
