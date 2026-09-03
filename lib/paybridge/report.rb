# frozen_string_literal: true

module Paybridge
  # Собирает предупреждения о неподдержанных/неоднозначных элементах спецификации.
  # Ничего не роняет — генерация продолжается, а пользователь видит, что упущено.
  class Report
    attr_reader :warnings

    def initialize
      @warnings = []
    end

    def warn(message)
      @warnings << message
      self
    end

    def any?
      @warnings.any?
    end

    def each(&block)
      @warnings.each(&block)
    end
  end
end
