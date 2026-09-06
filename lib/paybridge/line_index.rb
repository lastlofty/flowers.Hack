# frozen_string_literal: true

require 'psych'

module Paybridge
  # Отображение «путь в YAML -> номер строки исходной спеки». Строится по AST
  # Psych (сохраняет позиции), поэтому диагностика и source-map могут показывать
  # конкретную строку спецификации — как у сильных конкурентов (трассируемость).
  #
  # Безопасно: только чтение AST, никакого исполнения. Ошибки парсинга -> пустой
  # индекс (line_for вернёт nil), генерация не ломается.
  class LineIndex
    def initialize(content)
      tree = Psych.parse(content)
      @root = tree.is_a?(Psych::Nodes::Document) ? tree.root : tree
    rescue Psych::Exception, StandardError
      @root = nil
    end

    # Возвращает 1-based номер строки для пути (напр. line_for('paths','/pay','post')).
    # Для ключа мэппинга — строку ключа; nil, если путь не найден.
    def line_for(*path)
      return nil unless @root

      node = @root
      key_node = nil
      path.each do |segment|
        node, key_node = descend(node, segment)
        return nil if node.nil?
      end
      (key_node || node).start_line + 1
    end

    private

    def descend(node, segment)
      case node
      when Psych::Nodes::Mapping
        pairs(node).each do |key, value|
          return [value, key] if scalar_value(key) == segment.to_s
        end
        [nil, nil]
      when Psych::Nodes::Sequence
        index = Integer(segment, exception: false)
        child = index && node.children[index]
        [child, nil]
      else
        [nil, nil]
      end
    end

    def pairs(mapping)
      mapping.children.each_slice(2).to_a
    end

    def scalar_value(node)
      node.is_a?(Psych::Nodes::Scalar) ? node.value : nil
    end
  end
end
