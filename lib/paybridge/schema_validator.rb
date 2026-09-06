# frozen_string_literal: true

module Paybridge
  # Минимальный валидатор значения против OpenAPI-схемы (только stdlib, без
  # внешних гемов). Проверяет type/required/properties/items/enum рекурсивно.
  # Схема должна быть уже разрешена (resolve_deep) — $ref/allOf обработаны выше.
  # nil трактуется мягко (nullable/необязательное) — проверяем только присутствие
  # обязательных ключей и типы имеющихся значений.
  module SchemaValidator
    module_function

    def errors(value, schema, path = '')
      return [] unless schema.is_a?(Hash)

      errs = type_errors(value, schema, path)
      errs.concat(enum_errors(value, schema, path))
      errs
    end

    def type_errors(value, schema, path)
      case schema['type']
      when 'object'  then object_errors(value, schema, path)
      when 'array'   then array_errors(value, schema, path)
      when 'string'  then scalar(value, path, 'строка') { |v| v.is_a?(String) }
      when 'integer' then scalar(value, path, 'целое') { |v| v.is_a?(Integer) }
      when 'number'  then scalar(value, path, 'число') { |v| v.is_a?(Numeric) }
      when 'boolean' then scalar(value, path, 'булево') { |v| [true, false].include?(v) }
      else []
      end
    end

    def object_errors(value, schema, path)
      return [] if value.nil?
      return ["#{path}: ожидался object, получен #{value.class}"] unless value.is_a?(Hash)

      errs = []
      Array(schema['required']).each do |key|
        errs << "#{path}/#{key}: обязательное поле отсутствует" unless value.key?(key)
      end
      (schema['properties'] || {}).each do |key, sub|
        errs.concat(errors(value[key], sub, "#{path}/#{key}")) if value.key?(key)
      end
      errs
    end

    def array_errors(value, schema, path)
      return [] if value.nil?
      return ["#{path}: ожидался array"] unless value.is_a?(Array)
      return [] unless schema['items'].is_a?(Hash)

      value.each_with_index.flat_map { |item, i| errors(item, schema['items'], "#{path}[#{i}]") }
    end

    def scalar(value, path, name)
      return [] if value.nil?

      yield(value) ? [] : ["#{path}: ожидалась/ожидалось #{name}, получено #{value.class}"]
    end

    def enum_errors(value, schema, path)
      enum = schema['enum']
      return [] unless enum.is_a?(Array) && !value.nil? && !enum.include?(value)

      ["#{path}: значение #{value.inspect} не входит в enum #{enum.inspect}"]
    end
  end
end
