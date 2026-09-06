# frozen_string_literal: true

require 'openssl'
require 'json'

# ────────────────────────────────────────────────────────────────────────
# СГЕНЕРИРОВАНО PayBridge 1.0.0 из europay_api.yaml
# Провайдер: europay (EuroPay SEPA API v3.0.0)
# spec sha256: 2fabca5a34b11593d2945f237d7e13a48ae0d8978dc3014ad90fb794ea5fdbd6
# Не редактировать вручную — вывод детерминирован по спеке; изменения перезапишутся.
# ────────────────────────────────────────────────────────────────────────
module Provider
  class EuropayService < BaseService
    BASE_URL = ENV.fetch('EUROPAY_BASE_URL', 'https://sandbox.europay.example/v3')
    MIN_AMOUNT = 1

    STATUS_MAP = {
      'authorized' => 'in_progress',
      'captured' => 'approved',
      'declined' => 'rejected',
      'refunded' => 'rejected'
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
      return failure(:unprocessable_entity, 'amount_too_low') if operation.amount < MIN_AMOUNT
      if operation.payout_requisite.nil? || operation.payout_requisite.dig('sepa', 'iban').nil?
        return failure(:unprocessable_entity, 'missing_requisite', data: { field: 'iban' })
      end
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

    def process_callback(raw_body, signature = nil, _headers = {})
      payload = JSON.parse(raw_body)
      verify_signature!(raw_body, signature)

      case payload['event']
      when 'payment.captured'
        approve_operation(payload['payment_id'], map_status(payload['status']))
      when 'payment.declined', 'payment.refunded'
        reject_operation(payload['payment_id'], payload.dig('error', 'code'))
      else
        failure(:unprocessable_entity, 'unknown_event')
      end
    rescue JSON::ParserError, TypeError
      failure(:unprocessable_entity, 'invalid_json')
    end

    private


    def build_request_payload(operation, request_method = nil)
      requisite = operation.payout_requisite || {}
      {
        # Evidence (единица суммы, confidence 0.4): нет сигналов единицы в спеке -> по умолчанию major
        amount: operation.amount,
        currency: 'EUR',
        order_id: operation.id.to_s,
        recipient: {
          type: 'sepa',
          iban: requisite.dig('sepa', 'iban'),
          holder_name: requisite.dig('sepa', 'holder_name')
        }.compact
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
      { 'X-Auth-Token' => provider.credentials.fetch('api_key') }
    end

    def verify_signature!(raw_body, received)
      secret   = provider.credentials.fetch('callback_secret')
      expected = OpenSSL::HMAC.hexdigest('SHA256', secret, raw_body)

      return if received && secure_compare(expected, received)

      raise Provider::UnauthorizedError, 'invalid webhook signature'
    end

    def secure_compare(left, right)
      return false unless left.bytesize == right.bytesize

      OpenSSL.fixed_length_secure_compare(left, right)
    rescue StandardError
      false
    end

    def approve_operation(provider_operation_id, mapped_status)
      success(provider_operation_id: provider_operation_id, status: mapped_status || 'approved')
    end

    def reject_operation(provider_operation_id, error_code)
      failure(:rejected, error_code || 'rejected', data: { provider_operation_id: provider_operation_id })
    end
  end
end
