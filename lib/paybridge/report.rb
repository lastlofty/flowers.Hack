# frozen_string_literal: true

module Paybridge
  # Собирает диагностику о неподдержанных/неоднозначных элементах спецификации.
  # Ничего не роняет — генерация продолжается, а пользователь видит, что упущено.
  #
  # Каналы:
  #   * diagnostics — замечания с уровнем (:info | :warn | :error).
  #   * warnings    — производный плоский список текстов (обратная совместимость).
  #   * todos       — поля, которые НЕЛЬЗЯ вывести из спеки: их заполняет
  #                   разработчик вручную (field/where/hint) — чек-лист в CLI/отчёте.
  class Report
    attr_reader :todos, :diagnostics

    LEVELS = %i[info warn error].freeze

    Diagnostic = Struct.new(:level, :message, keyword_init: true) do
      def to_h = { level: level.to_s, message: message }
    end

    # Поле для ручного заполнения: что заполнить, где в коде и подсказка как.
    Todo = Struct.new(:field, :where, :hint, keyword_init: true) do
      def to_h = { field: field, where: where, hint: hint }
    end

    def initialize
      @diagnostics = []
      @todos = []
    end

    # level: :info (безобидно, к сведению) | :warn (принято допущение, проверьте) |
    #        :error (сервис неполный/некорректен без вмешательства).
    def warn(message, level: :warn)
      level = :warn unless LEVELS.include?(level)
      @diagnostics << Diagnostic.new(level: level, message: message)
      self
    end

    # Плоский список текстов — как раньше (CLI/веб/тесты, ожидающие строки).
    def warnings
      @diagnostics.map(&:message)
    end

    def diagnostics_by_level
      @diagnostics.group_by(&:level).transform_values { |list| list.map(&:message) }
    end

    # Поле, которое провайдер требует, но мы не смогли сопоставить из спеки.
    def todo(field:, where:, hint:)
      @todos << Todo.new(field: field, where: where, hint: hint)
      self
    end

    def any?
      @diagnostics.any?
    end

    def todos?
      @todos.any?
    end

    def each(&block)
      warnings.each(&block)
    end
  end
end
