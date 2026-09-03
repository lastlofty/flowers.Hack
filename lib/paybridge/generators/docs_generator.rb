# frozen_string_literal: true

require_relative 'base_generator'

module Paybridge
  module Generators
    # Генерирует INTEGRATION.md — гайд интеграции.
    class DocsGenerator < BaseGenerator
      def filename
        'INTEGRATION.md'
      end

      def render
        render_template('integration.md.erb')
      end
    end
  end
end
