# frozen_string_literal: true

module Paybridge
  # Единый безопасный способ вставлять данные спецификации в генерируемый Ruby.
  # Спецификация — недоверенный ввод: имена, статусы, URL могут содержать кавычки,
  # обратные слеши, переводы строк и последовательности интерполяции `#{...}`.
  module Safe
    module_function

    PROVIDER_RE = /\A[a-z][a-z0-9_]{1,32}\z/
    IDENT_RE    = /\A[a-zA-Z_][a-zA-Z0-9_]*\z/

    # Валидирует имя провайдера (одинаково для CLI и фасада). Заодно исключает
    # выход пути результата за пределы папки (в имени только [a-z0-9_]).
    def provider!(name)
      s = name.to_s
      return s if s.match?(PROVIDER_RE)

      raise GenerationError,
            "Некорректное имя провайдера: #{s.inspect} (ожидается ^[a-z][a-z0-9_]{1,32}$)"
    end

    # Имя класса сервиса из валидированного провайдера (безопасный идентификатор).
    def class_name(provider)
      provider!(provider).split('_').map(&:capitalize).join + 'Service'
    end

    # Ruby-литерал строки в ОДИНАРНЫХ кавычках: экранирует `\` и `'`.
    # Одинарные кавычки не интерполируют, поэтому `#{...}` внутри — инертный текст.
    def rb(value)
      escaped = value.to_s.gsub(/([\\'])/) { "\\#{Regexp.last_match(1)}" }
      "'#{escaped}'"
    end

    # Символьный литерал: :ident либо :'экранированное'.
    def sym(value)
      s = value.to_s
      s.match?(IDENT_RE) ? ":#{s}" : ":#{rb(s)}"
    end

    # Исходник ключа хэша: `name:` для валидного идентификатора, иначе `"name" =>`.
    def hash_key(name)
      s = name.to_s
      s.match?(IDENT_RE) ? "#{s}:" : "#{rb(s)} =>"
    end

    # Однострочный безопасный текст для комментария (переводы строк убираем).
    def comment(value)
      value.to_s.gsub(/[[:space:]]+/, ' ').strip
    end
  end
end
