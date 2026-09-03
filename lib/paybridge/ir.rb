# frozen_string_literal: true

module Paybridge
  module IR
    # Один HTTP-метод API: путь, глагол, назначение, коды ответов.
    Endpoint = Struct.new(
      :http_method, :path, :operation_id, :summary,
      :role,            # :create | :status | :cancel | :webhook | :other
      :path_params, :query_params, :header_params,
      :request_schema, :response_codes,
      keyword_init: true
    ) do
      def to_s
        "#{http_method.upcase} #{path}"
      end
    end

    # Требования к авторизации.
    Auth = Struct.new(
      :scheme_type,        # 'apiKey' | 'http' | ...
      :location,           # 'header' | 'query'
      :header_name,        # напр. X-API-Key
      :credentials_field,  # ключ в providers.credentials
      keyword_init: true
    )

    # Входящие уведомления.
    Webhook = Struct.new(
      :path, :events, :event_actions, :id_field,
      :signature_header, :signature_alg, :callback_secret_field,
      keyword_init: true
    )

    # Полная модель спецификации — то, что отдаёт SpecParser и потребляют генераторы.
    Spec = Struct.new(
      :provider_name,        # 'novapay' (из CLI)
      :provider_class,       # 'NovapayService'
      :title, :version,
      :base_url, :base_url_env,
      :auth,
      :idempotency_header,   # напр. Idempotency-Key или nil
      :endpoints,
      :create_endpoint, :status_endpoint, :cancel_endpoint, :webhook,
      :status_map,           # { 'pending' => 'in_progress', ... }
      :error_map,            # { 400 => 'validation_error', ... }
      :http_symbol,          # { 400 => 'bad_request', ... }
      :amount,               # { field:, minor_units:, min_major: } или nil
      :currency,             # 'RUB' или nil
      :external_id_field,    # 'external_id'
      :request_payload_ruby, # готовый Ruby-литерал тела запроса (строка)
      :request_examples, :response_examples, :webhook_examples,
      :report,
      keyword_init: true
    )
  end
end
