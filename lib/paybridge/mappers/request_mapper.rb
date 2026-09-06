# frozen_string_literal: true

require_relative '../safe'

module Paybridge
  module Mappers
    # Строит тело запроса создания операции: из JSON-схемы запроса генерирует
    # готовый Ruby-литерал хэша для вставки в шаблон сервиса.
    #
    # Конвенции (не привязаны к конкретному провайдеру):
    #   * поле-сумма в минорных единицах  -> amount_in_minor_units(operation.amount)
    #   * поле-валюта с единственным enum  -> строковый литерал этого значения
    #   * поле external_id / merchant id   -> operation.id.to_s
    #   * вложенный объект (реквизиты)      -> operation.payout_requisite.dig(group, field)
    #   * остальные скаляры                 -> operation.<field> (с предупреждением)
    class RequestMapper
      Result = Struct.new(:ruby, :amount, :currency, :external_id_field, :required_requisite,
                          :recipient_spec, keyword_init: true)

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
        @required_requisite = []
        @recipient_spec = nil
      end

      def build(schema)
        schema ||= {}
        ruby = emit_object(schema, 1)
        warn_guessed_required_if
        Result.new(
          ruby: ruby,
          amount: @amount,
          currency: @currency,
          external_id_field: @external_id_field,
          required_requisite: @required_requisite,
          recipient_spec: @recipient_spec
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

          @pending_comment = nil
          value = value_expr(name, prop, depth, group, required.include?(name))
          # Комментарий-маркер ставим НАД полем (не в хвост), иначе запятая
          # объединения хэша уедет внутрь комментария и сломает синтаксис.
          prefix = @pending_comment ? "#{indent(depth)}# #{@pending_comment}\n" : ''
          lines << "#{prefix}#{indent(depth)}#{Safe.hash_key(name)} #{value}"
        end

        body = lines.join(",\n")
        suffix = optional_present?(props, required, group) ? '.compact' : ''
        "{\n#{body}\n#{close_indent(depth)}}#{suffix}"
      end

      def value_expr(name, prop, depth, _group, required)
        if prop['type'] == 'object' || prop['properties']
          if monetary_amount?(name, prop)
            return emit_amount_object(name, prop)
          end

          type_enum = nested_type_enum(prop)
          group = object_group(prop)
          if type_enum.size > 1
            # Несколько способов (sbp/card): выбор в рантайме через request_method.
            record_recipient_spec(name, prop, type_enum)
            'build_recipient(operation, requisite, request_method)'
          elsif group
            emit_nested(prop, depth + 1, group)
          else
            # Вложенный объект без дискриминатора type — не знаем, как сопоставить.
            manual_field(name,
                         'вложенный объект без поля type — соберите хэш вручную ' \
                         'из operation/requisite или задайте overrides', required)
          end
        elsif amount_field?(name, prop)
          record_amount(name, prop)
          @amount[:minor_units] ? 'amount_in_minor_units(operation.amount)' : 'operation.amount'
        elsif currency_field?(name, prop)
          record_currency(prop)
        elsif external_field?(name, prop)
          @external_id_field = name
          'operation.id.to_s'
        elsif name == 'type' && single_enum?(prop)
          Safe.rb(prop['enum'].first)
        elsif @current_group
          "requisite.dig(#{Safe.rb(@current_group)}, #{Safe.rb(name)})"
        else
          # Поле верхнего уровня без известного правила сопоставления НЕ превращаем
          # в operation.<имя> (вызов несуществующего метода). Оставляем nil и
          # помечаем как поле для ручного заполнения.
          manual_field(name, manual_hint(prop), required)
        end
      end

      # Поле, которое не выводится из спеки:
      #   * required -> структурированный TODO (провайдер требует, надо заполнить);
      #   * optional -> мягкое предупреждение (nil уберётся .compact при отправке).
      # В обоих случаях возвращает nil и ставит комментарий-маркер над строкой.
      def manual_field(name, hint, required)
        where = @current_group ? "requisite[#{@current_group.inspect}]" : 'create_request payload'
        if required
          @report.todo(field: name, where: where, hint: hint)
          @pending_comment = "TODO(PayBridge): заполните '#{name}' вручную — #{hint}"
        else
          @report.warn("Необязательное поле '#{name}' не сопоставлено — отправляется nil " \
                       '(убирается .compact). Заполните вручную при необходимости.')
          @pending_comment = "optional: '#{name}' не сопоставлено — заполните при необходимости"
        end
        'nil'
      end

      # Подсказка «как заполнить», опираясь на тип/формат поля из спеки.
      def manual_hint(prop)
        type = prop['type']
        fmt  = prop['format']
        base =
          case type
          when 'string'  then fmt ? "строка (#{fmt})" : 'строка'
          when 'integer', 'number' then 'число'
          when 'boolean' then 'булево (true/false)'
          when 'array'   then 'массив'
          else type ? type.to_s : 'значение'
        end
        example = prop['example'] || prop['default']
        hint = "тип: #{base}; провайдер требует это поле — задайте выражение " \
               'из operation/requisite или добавьте правило в overrides'
        example ? "#{hint} (пример: #{example})" : hint
      end

      def emit_nested(schema, depth, group)
        @current_group = group
        props    = schema['properties'] || {}
        required = schema['required'] || []
        lines = []
        props.each do |name, prop|
          next if skip_field?(name, prop, group)

          value = if name == 'type' && single_enum_or_example?(prop)
                    Safe.rb(group)
                  elsif prop['type'] == 'object'
                    emit_nested(prop, depth + 1, object_group(prop))
                  else
                    "requisite.dig(#{Safe.rb(group)}, #{Safe.rb(name)})"
                  end
          lines << "#{indent(depth)}#{Safe.hash_key(name)} #{value}"

          if name != 'type' && group && required_for_group?(name, prop, required, group)
            @required_requisite << [group, name]
          end
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
        if prop.key?('minimum')
          minimum = prop['minimum']
          unless minimum.is_a?(Integer) || (minimum.is_a?(Float) && minimum.finite?)
            raise GenerationError, "Поле '#{name}.minimum' должно быть конечным числом"
          end
        end
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
        # Храним минимум в НАТИВНЫХ единицах спеки (без деления — иначе теряются
        # копейки: 150 центов -> 1). Сравнение генерится в правильных единицах.
        @amount = { field: name, minor_units: minor, min_native: prop['minimum'] }
      end

      def record_currency(prop)
        @currency = prop['enum'].first
        Safe.rb(@currency)
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

      # Поле обязательно для выбранного способа: оно в required, либо ограничено
      # этим type через overrides/description.
      def required_for_group?(name, prop, required, group)
        return true if required.include?(name)

        restriction = override_required_if(name) || prop['description'].to_s[/type=(\w+)/, 1]
        restriction == group
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

      # Сумма как объект { value, currency } (напр. ЮKassa), а не скаляр.
      def monetary_amount?(name, prop)
        name.to_s.match?(AMOUNT_HINT) && (prop['properties'] || {}).key?('value')
      end

      # Литерал amount-объекта: value как строка с 2 знаками, currency из enum.
      def emit_amount_object(name, prop)
        props = prop['properties'] || {}
        value_field = props.key?('value') ? 'value' : props.keys.first
        currency_field = props.key?('currency') ? 'currency' : nil

        @amount = { field: name, minor_units: false, min_native: nil, object: true }

        pairs = ["#{Safe.hash_key(value_field)} format('%.2f', operation.amount)"]
        if currency_field
          pairs << "#{Safe.hash_key(currency_field)} #{amount_currency_expr(props[currency_field])}"
        end
        "{ #{pairs.join(', ')} }"
      end

      def amount_currency_expr(currency_prop)
        enum = currency_prop.is_a?(Hash) ? currency_prop['enum'] : nil
        return Safe.rb(enum.first) if enum.is_a?(Array) && enum.size == 1

        if enum.is_a?(Array) && !enum.empty?
          @currency = enum.first
          @report.warn("Валюта суммы: несколько значений enum — принято '#{enum.first}'. " \
                       'Уточните при необходимости.')
          Safe.rb(enum.first)
        else
          "operation.currency || 'RUB'"
        end
      end

      # enum значений поля type у вложенного объекта (способы выплаты).
      def nested_type_enum(prop)
        type_prop = (prop['properties'] || {})['type']
        enum = type_prop.is_a?(Hash) ? type_prop['enum'] : nil
        enum.is_a?(Array) ? enum : []
      end

      # Описатель recipient с несколькими способами: поля и обязательные per-способ.
      def record_recipient_spec(name, prop, type_enum)
        props = prop['properties'] || {}
        required = prop['required'] || []
        methods = {}

        type_enum.each do |type|
          fields = []
          req = []
          props.each do |fname, fprop|
            next if fname == 'type'

            restriction = field_restriction(fname, fprop)
            next if restriction && restriction != type # поле другого способа

            fields << fname
            req << fname if required.include?(fname) || restriction == type
          end
          methods[type.to_s] = { 'fields' => fields, 'required' => req }
        end

        @recipient_spec = { 'field' => name, 'methods' => methods }
      end

      # Ограничение поля по способу: overrides -> текст description (догадка).
      def field_restriction(name, prop)
        ov = override_required_if(name)
        return ov if ov

        guess = prop['description'].to_s[/type=(\w+)/, 1]
        @guessed_required_if << name if guess
        guess
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

    end
  end
end
