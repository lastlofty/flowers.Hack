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

    # confidence (0..1) и evidence (цитата из спеки) — объяснимость выводов:
    # почему принято именно это допущение и насколько мы уверены.
    Diagnostic = Struct.new(:level, :message, :confidence, :evidence, keyword_init: true) do
      def to_h
        base = { level: level.to_s, message: message }
        base[:confidence] = confidence if confidence
        base[:evidence] = evidence if evidence
        base
      end
    end

    # Поле для ручного заполнения: что заполнить, где в коде, подсказка и (если
    # удалось) строка в исходной спеке (source-map).
    Todo = Struct.new(:field, :where, :hint, :line, keyword_init: true) do
      def to_h
        base = { field: field, where: where, hint: hint }
        line ? base.merge(line: line) : base
      end
    end

    def initialize
      @diagnostics = []
      @todos = []
    end

    # level: :info (безобидно, к сведению) | :warn (принято допущение, проверьте) |
    #        :error (сервис неполный/некорректен без вмешательства).
    def warn(message, level: :warn, confidence: nil, evidence: nil)
      level = :warn unless LEVELS.include?(level)
      @diagnostics << Diagnostic.new(level: level, message: message, confidence: confidence, evidence: evidence)
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
    def todo(field:, where:, hint:, line: nil)
      @todos << Todo.new(field: field, where: where, hint: hint, line: line)
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
