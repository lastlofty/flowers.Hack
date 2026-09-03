# frozen_string_literal: true

require_relative 'base_generator'

module Paybridge
  module Generators
    # Генерирует исполняемый тест <provider>_service_spec.rb (minitest),
    # который гоняет fixtures.json против сгенерированного сервиса.
    class TestGenerator < BaseGenerator
      def filename
        "#{spec.provider_name}_service_spec.rb"
      end

      def render
        render_template('service_spec.rb.erb')
      end
    end
  end
end
