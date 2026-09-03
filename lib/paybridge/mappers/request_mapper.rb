# frozen_string_literal: true

module Paybridge
  module Mappers
    # Строит тело запроса создания операции: из JSON-схемы запроса генерирует
    # готовый Ruby-литерал хэша для вставки в шаблон сервиса.
    #
    # Конвенции (не привязаны к конкретному провайдеру):
    #   * поле-сумма в минорных единицах  -> (operation.amount * 100).to_i
    #   * поле-валюта с единственным enum  -> строковый литерал этого значения
    #   * поле external_id / merchant id   -> operation.id.to_s
    #   * вложенный объект (реквизиты)      -> operation.payout_requisite.dig(group, field)
    #   * остальные скаляры                 -> operation.<field> (с предупреждением)
    class RequestMapper
      Result = Struct.new(:ruby, :amount, :currency, :external_id_field, keyword_init: true)

      AMOUNT_HINT   = /\b(amount|sum|total)\b/i
      MINOR_HINT    = /копей|kopeck|копейк|цент|cents?|minor/i
      CURRENCY_HINT = /\b(currency|ccy)\b/i
      EXTERNAL_HINT = /\b(external_id|merchant_id|order_id|reference)\b/i

      def initialize(report, overrides = {})
        @report = report
        @overrides = overrides || {}
        @amount = nil
        @currency = nil
        @external_id_field = nil
        @guessed_required_if = []
      end

      def build(schema)
        schema ||= {}
        ruby = emit_object(schema, 1)
        warn_guessed_required_if
        Result.new(
          ruby: ruby,
          amount: @amount,
          currency: @currency,
          external_id_field: @external_id_field
        )
      end

      private

      def emit_object(schema, depth)
        props    = schema['properties'] || {}
        required = schema['required'] || []
        group    = object_group(schema)

        lines = []
        props.each do |name, prop|
          next if skip_field?(name, prop, group)

          value = value_expr(name, prop, depth, group)
          lines << "#{indent(depth)}#{name}: #{value}"
        end

        body = lines.join(",\n")
        suffix = optional_present?(props, required, group) ? '.compact' : ''
        "{\n#{body}\n#{close_indent(depth)}}#{suffix}"
      end

      def value_expr(name, prop, depth, _group)
        if prop['type'] == 'object' || prop['properties']
          nested_group = object_group(prop)
          emit_nested(prop, depth + 1, nested_group)
        elsif amount_field?(name, prop)
          record_amount(name, prop)
          @amount[:minor_units] ? '(operation.amount * 100).to_i' : 'operation.amount'
        elsif currency_field?(name, prop)
          record_currency(prop)
        elsif external_field?(name, prop)
          @external_id_field = name
          'operation.id.to_s'
        elsif name == 'type' && single_enum?(prop)
          quote(prop['enum'].first)
        else
          # реквизиты вложенного объекта берём из operation.payout_requisite
          @current_group ? "requisite.dig(#{quote(@current_group)}, #{quote(name)})"
                         : "operation.#{name}"
        end
      end

      def emit_nested(schema, depth, group)
        @current_group = group
        props    = schema['properties'] || {}
        required = schema['required'] || []
        lines = []
        props.each do |name, prop|
          next if skip_field?(name, prop, group)

          value = if name == 'type' && single_enum_or_example?(prop)
                    quote(group)
                  elsif prop['type'] == 'object'
                    emit_nested(prop, depth + 1, object_group(prop))
                  else
                    "requisite.dig(#{quote(group)}, #{quote(name)})"
                  end
          lines << "#{indent(depth)}#{name}: #{value}"
        end
        @current_group = nil
        suffix = optional_present?(props, required, group) ? '.compact' : ''
        "{\n#{lines.join(",\n")}\n#{close_indent(depth)}}#{suffix}"
      end

      # --- эвристики распознавания полей -----------------------------------

      def amount_field?(name, prop)
        name.to_s.match?(AMOUNT_HINT) && prop['type'] == 'integer'
      end

      def currency_field?(name, prop)
        name.to_s.match?(CURRENCY_HINT) && single_enum?(prop)
      end

      def external_field?(name, _prop)
        name.to_s.match?(EXTERNAL_HINT)
      end

      def minor_units?(prop)
        prop['description'].to_s.match?(MINOR_HINT) ||
          (prop['type'] == 'integer' && prop['minimum'].to_i >= 1000)
      end

      def record_amount(name, prop)
        unit = @overrides['amount_unit']
        minor =
          if unit
            unit.to_s == 'minor'
          else
            guessed = minor_units?(prop)
            @report.warn(
              "Единица суммы не выражается в OpenAPI: принята " \
              "'#{guessed ? 'minor' : 'major'}' (по описанию/минимуму). " \
              'Уточните overrides.amount_unit при необходимости.'
            )
            guessed
          end
        min = prop['minimum']
        min_major = if min && minor then (min / 100) elsif min then min else nil end
        @amount = { field: name, minor_units: minor, min_major: min_major }
      end

      def record_currency(prop)
        @currency = prop['enum'].first
        quote(@currency)
      end

      # Поле пропускаем, если оно принадлежит другому type=<...>.
      # Приоритет: overrides.required_if -> текст description (это уже догадка).
      def skip_field?(name, prop, group)
        restricted = override_required_if(name)
        if restricted.nil?
          guess = prop['description'].to_s[/type=(\w+)/, 1]
          if guess && group
            @guessed_required_if << name
            restricted = guess
          end
        end
        return false if restricted.nil? || group.nil?

        restricted != group
      end

      def override_required_if(name)
        rule = @overrides.dig('required_if', name)
        return nil if rule.nil?

        rule.is_a?(Hash) ? rule['equals'] : rule
      end

      def warn_guessed_required_if
        @guessed_required_if.uniq.each do |name|
          @report.warn(
            "Условная обязательность поля '#{name}' выведена из текста description. " \
            'Уточните overrides.required_if при необходимости.'
          )
        end
      end

      # Группа вложенного объекта = дефолтное значение поля type (первый enum / example).
      def object_group(schema)
        props = schema['properties'] || {}
        type_prop = props['type']
        return nil unless type_prop

        (type_prop['enum'] && type_prop['enum'].first) || type_prop['example']
      end

      def optional_present?(props, required, group)
        props.any? do |name, prop|
          next false if skip_field?(name, prop, group)

          !required.include?(name)
        end
      end

      def single_enum?(prop)
        prop['enum'].is_a?(Array) && prop['enum'].size == 1
      end

      def single_enum_or_example?(prop)
        (prop['enum'] && !prop['enum'].empty?) || prop['example']
      end

      def indent(depth)
        ' ' * (6 + depth * 2)
      end

      def close_indent(depth)
        ' ' * (6 + (depth - 1) * 2)
      end

      def quote(value)
        "'#{value}'"
      end
    end
  end
end
