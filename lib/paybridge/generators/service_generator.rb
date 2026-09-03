# frozen_string_literal: true

require_relative 'base_generator'

module Paybridge
  module Generators
    # Генерирует <provider>_service.rb по контракту Provider::BaseService.
    class ServiceGenerator < BaseGenerator
      def filename
        "#{spec.provider_name}_service.rb"
      end

      def render
        render_template('service.rb.erb')
      end
    end
  end
end
