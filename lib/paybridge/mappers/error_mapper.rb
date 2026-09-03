# frozen_string_literal: true

module Paybridge
  module Mappers
    # Сопоставляет HTTP-коды провайдера с внутренними кодами ошибок и символами
    # статуса ответа. Правила — из config/mapping.yml.
    class ErrorMapper
      def initialize(config, report)
        @error_map   = config['error_map'] || {}
        @http_symbol = config['http_symbol'] || {}
        @report      = report
      end

      # http_codes — массив кодов ответа (Integer), встреченных в спецификации.
      # Возвращает два хэша: код -> внутренний код ошибки, код -> символ статуса.
      def build(http_codes)
        error = {}
        symbol = {}
        http_codes.select { |c| c >= 400 }.sort.each do |code|
          entry = @error_map[code.to_s]
          if entry.nil?
            @report.warn("HTTP #{code} не описан в mapping.yml — трактую как internal_error")
            error[code]  = 'internal_error'
            symbol[code] = 'internal_server_error'
          else
            error[code]  = entry['code']
            symbol[code] = @http_symbol[code.to_s] || 'internal_server_error'
          end
        end
        [error, symbol]
      end

      def action_for(code)
        (@error_map[code.to_s] || {})['action']
      end
    end
  end
end
