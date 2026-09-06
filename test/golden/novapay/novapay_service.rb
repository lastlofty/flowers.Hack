# frozen_string_literal: true

require 'openssl'
require 'json'
require 'bigdecimal'

# ────────────────────────────────────────────────────────────────────────
# СГЕНЕРИРОВАНО PayBridge 1.0.0 из provider_api.yaml
# Провайдер: novapay (NovaPay Payout API v1.0.0)
# spec sha256: 415f50ee36fb331dfab49ceed0e8ed3b0ebe16053d7e00dbabd32282f4396551
# Не редактировать вручную — вывод детерминирован по спеке; изменения перезапишутся.
# ────────────────────────────────────────────────────────────────────────
module Provider
  class NovapayService < BaseService
    BASE_URL = ENV.fetch('NOVAPAY_BASE_URL', 'https://api.sandbox.novapay.example/v1')
    MIN_AMOUNT = 100000

    STATUS_MAP = {
      'pending' => 'in_progress',
      'processing' => 'in_progress',
      'completed' => 'approved',
      'failed' => 'rejected',
      'cancelled' => 'rejected'
    }.freeze

    ERROR_MAP = {
      400 => 'validation_error',
      401 => 'invalid_credentials',
      402 => 'insufficient_balance',
      404 => 'not_found',
      409 => 'duplicate',
      422 => 'validation_error',
      429 => 'rate_limit',
      500 => 'internal_error'
    }.freeze

    HTTP_STATUS_SYMBOL = {
      400 => :bad_request,
      401 => :unauthorized,
      402 => :payment_required,
      404 => :not_found,
      409 => :conflict,
      422 => :unprocessable_entity,
      429 => :too_many_requests,
      500 => :internal_server_error
    }.freeze

    PAYOUT_METHODS = ['sbp', 'card'].freeze
    REQUIRED_REQUISITE = {
      'sbp' => ['phone', 'bank_code'],
      'card' => ['phone', 'card_number']
    }.freeze

    def check_conditions(operation, request_method)
      base_result = super
      return base_result if base_result.failed?
      return failure(:unprocessable_entity, 'amount_too_low') if amount_in_minor_units(operation.amount) < MIN_AMOUNT
      method = payout_method(operation, request_method)
      REQUIRED_REQUISITE.fetch(method, []).each do |field|
        if (operation.payout_requisite || {}).dig(method, field).nil?
          return failure(:unprocessable_entity, 'missing_requisite', data: { field: field, method: method })
        end
      end
      success
    end

    def create_request(operation, request_method = 'create')
      payload  = build_request_payload(operation, request_method)
      response = client.post(
        "#{BASE_URL}/payouts",
        json: payload,
        headers: auth_headers.merge('Idempotency-Key' => idempotency_key(operation))
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
        "#{BASE_URL}/payouts/#{operation.provider_operation_id}",
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
      when 'payout.completed', 'payout.processing'
        approve_operation(payload['payout_id'], map_status(payload['status']))
      when 'payout.failed', 'payout.cancelled'
        reject_operation(payload['payout_id'], payload.dig('error', 'code'))
      else
        failure(:unprocessable_entity, 'unknown_event')
      end
    rescue JSON::ParserError, TypeError
      failure(:unprocessable_entity, 'invalid_json')
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
        currency: 'RUB',
        external_id: operation.id.to_s,
        recipient: build_recipient(operation, requisite, request_method)
      }
    end

    # Способ выплаты: явный request_method, иначе по наличию реквизитов, иначе первый.
    def payout_method(operation, request_method)
      return request_method if PAYOUT_METHODS.include?(request_method)

      present = PAYOUT_METHODS.find { |type| (operation.payout_requisite || {}).key?(type) }
      present || PAYOUT_METHODS.first
    end

    def build_recipient(operation, requisite, request_method)
      case payout_method(operation, request_method)
      when 'sbp'
        { type: 'sbp', phone: requisite.dig('sbp', 'phone'), bank_code: requisite.dig('sbp', 'bank_code'), bank_name: requisite.dig('sbp', 'bank_name') }.compact
      when 'card'
        { type: 'card', phone: requisite.dig('card', 'phone'), bank_name: requisite.dig('card', 'bank_name'), card_number: requisite.dig('card', 'card_number') }.compact
      end
    end

    def parse_create_response(_operation, response)
      case response.status
      when 201
        parse_success_response(response)
      when 409
        # 409 — успех только если провайдер вернул уже созданную операцию.
        body = response.body.is_a?(Hash) ? response.body : {}
        if body['id'] && map_status(body['status'])
          success(provider_operation_id: body['id'], status: map_status(body['status']))
        else
          map_error(response)
        end
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
      { 'X-API-Key' => provider.credentials.fetch('api_key') }
    end

    def idempotency_key(operation)
      operation.idempotency_key || operation.id.to_s
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
