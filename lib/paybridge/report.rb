# frozen_string_literal: true

module Paybridge
  # Собирает предупреждения о неподдержанных/неоднозначных элементах спецификации.
  # Ничего не роняет — генерация продолжается, а пользователь видит, что упущено.
  #
  # Два канала:
  #   * warnings — общие замечания (текст).
  #   * todos    — поля, которые НЕЛЬЗЯ вывести из спеки: их должен заполнить
  #                разработчик вручную. Структурированы (field/where/hint), чтобы
  #                показать чек-листом в CLI, отчёте и веб-интерфейсе.
  class Report
    attr_reader :warnings, :todos

    # Поле для ручного заполнения: что заполнить, где в коде и подсказка как.
    Todo = Struct.new(:field, :where, :hint, keyword_init: true) do
      def to_h = { field: field, where: where, hint: hint }
    end

    def initialize
      @warnings = []
      @todos = []
    end

    def warn(message)
      @warnings << message
      self
    end

    # Поле, которое провайдер требует, но мы не смогли сопоставить из спеки.
    # Возвращает готовый комментарий-маркер для вставки в сгенерированный код.
    def todo(field:, where:, hint:)
      @todos << Todo.new(field: field, where: where, hint: hint)
      self
    end

    def any?
      @warnings.any?
    end

    def todos?
      @todos.any?
    end

    def each(&block)
      @warnings.each(&block)
    end
  end
end
