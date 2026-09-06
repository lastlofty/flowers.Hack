# frozen_string_literal: true

require 'json'

module Paybridge
  module Generators
    # generation.json — машиночитаемый вердикт о допуске интеграции (для CI/приёмки),
    # как admission-gate у сильных конкурентов. Собирает блокеры из структуры спеки
    # и говорит: admitted (готово к настройке) или нет, с причинами.
    #
    # admitted == true, если нет критических блокеров. Обязательные несопоставленные
    # поля и критические риски безопасности — блокеры; предупреждения — нет.
    class VerdictGenerator
      attr_reader :spec

      def initialize(spec, **_opts)
        @spec = spec
      end

      def filename
        'generation.json'
      end

      def render
        blockers = collect_blockers
        # Нормализуем пустые массивы: JSON.pretty_generate печатает их по-разному в
        # C-расширении ("[]") и чистом Ruby ("[\n]") — иначе golden дрейфует CI/Windows.
        json = JSON.pretty_generate(report(blockers)).gsub(/\[\n\s*\]/, '[]')
        "#{json}\n"
      end

      private

      def report(blockers)
        by = spec.report.diagnostics_by_level
        {
          'provider' => spec.provider_name,
          'generator' => "PayBridge #{Paybridge::VERSION}",
          'spec_sha256' => spec.spec_sha256,
          'admitted' => blockers.empty?,
          'verdict' => verdict(blockers, by),
          'blockers' => blockers,
          'manual_fields' => spec.report.todos.size,
          'diagnostics' => {
            'error' => (by[:error] || []).size,
            'warn' => (by[:warn] || []).size,
            'info' => (by[:info] || []).size
          }
        }
      end

      def collect_blockers
        list = []
        list << 'нет метода создания операции (POST)' if spec.create_endpoint.nil?
        list << 'ошибки разбора спецификации' if (spec.report.diagnostics_by_level[:error] || []).any?
        list << 'авторизация не определена' if spec.auth.nil?
        list << 'BASE_URL не по HTTPS' unless spec.base_url.to_s.start_with?('https://')
        if spec.webhook && spec.webhook.signature_header.nil?
          list << 'webhook без подписи — верификация не генерируется'
        end
        unless spec.report.todos.empty?
          list << "#{spec.report.todos.size} обязательных полей требуют ручного заполнения"
        end
        list
      end

      def verdict(blockers, by_level)
        return 'blocked' if (by_level[:error] || []).any? || spec.create_endpoint.nil?
        return 'needs_attention' unless blockers.empty?

        'ready'
      end
    end
  end
end
