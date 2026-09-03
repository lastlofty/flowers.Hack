# frozen_string_literal: true

module Paybridge
  module Mappers
    # Сопоставляет статусы провайдера со статусами Space Payments по правилам
    # из config/mapping.yml. Неизвестные статусы попадают в report.
    class StatusMapper
      def initialize(config, report)
        @table   = (config['status_map'] || {}).transform_keys(&:downcase)
        @default = config['unknown_status_default'] || 'in_progress'
        @report  = report
      end

      # provider_statuses — массив строк из enum статуса в спецификации.
      # Возвращает упорядоченный хэш { 'pending' => 'in_progress', ... }.
      def build(provider_statuses)
        provider_statuses.each_with_object({}) do |status, acc|
          mapped = @table[status.to_s.downcase]
          if mapped.nil?
            @report.warn("Статус '#{status}' не найден в mapping.yml — использую '#{@default}'")
            mapped = @default
          end
          acc[status.to_s] = mapped
        end
      end
    end
  end
end
