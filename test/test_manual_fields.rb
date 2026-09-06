# frozen_string_literal: true

require 'minitest/autorun'
require 'tempfile'
require 'rbconfig'
require_relative '../lib/paybridge'

# Поля, которые нельзя вывести из спеки, помечаются как «заполнить вручную»:
# структурированный TODO + комментарий-маркер в коде + компилируемый nil.
class TestManualFields < Minitest::Test
  SPEC = <<~YAML
    openapi: 3.0.3
    info: { title: T, version: "1.0.0" }
    servers: [ { url: https://x.example/v1 } ]
    paths:
      /pay:
        post:
          operationId: create
          security: []
          requestBody:
            required: true
            content:
              application/json:
                schema:
                  type: object
                  required: [amount, merchant_note]
                  properties:
                    amount: { type: integer, minimum: 100 }
                    merchant_note: { type: string, format: text, example: "заказ №42" }
                    marketing_tag: { type: string }
          responses:
            '201': { description: ok, content: { application/json: { schema: { type: object, properties: { id: {type: string}, status: {type: string, enum: [pending, done]} } } } } }
  YAML

  def gen
    f = Tempfile.new(['s', '.yaml'])
    f.write(SPEC)
    f.rewind
    Paybridge.generate(spec_path: f.path, provider: 'manualpay')
  ensure
    f.close!
  end

  def test_unmapped_field_becomes_structured_todo
    g = gen
    todo = g.todos.find { |t| t[:field] == 'merchant_note' }
    refute_nil todo, "ожидался TODO по merchant_note, есть: #{g.todos.inspect}"
    assert_includes todo[:where], 'create_request'
    assert_includes todo[:hint], 'строка'
    assert_includes todo[:hint], 'заказ №42' # пример из спеки попал в подсказку
    assert_operator todo[:line], :>, 0, 'у поля есть строка в спеке (source-map)'
  end

  def test_optional_unmapped_field_is_warning_not_todo
    g = gen
    # Необязательное поле не попадает в TODO (nil уберётся .compact), но
    # фиксируется мягким предупреждением.
    refute g.todos.any? { |t| t[:field] == 'marketing_tag' },
           "optional-поле не должно быть TODO: #{g.todos.inspect}"
    assert g.warnings.any? { |w| w.include?('marketing_tag') },
           "ожидалось предупреждение по marketing_tag: #{g.warnings.inspect}"
    code = g.files['manualpay_service.rb']
    refute_includes code, "заполните 'marketing_tag' вручную" # не алармируем
    assert_includes code, "optional: 'marketing_tag'"          # но помечаем
  end

  def test_service_has_inline_marker_and_compiles
    code = gen.files['manualpay_service.rb']
    assert_includes code, "TODO(PayBridge): заполните 'merchant_note' вручную"
    assert_includes code, 'merchant_note: nil'
    # amount по-прежнему сопоставлен (не помечен вручную)
    refute_includes code, "заполните 'amount'"
    assert syntax_ok?(code), code
  end

  def syntax_ok?(code)
    f = Tempfile.new(['svc', '.rb'])
    f.write(code)
    f.rewind
    out = `"#{RbConfig.ruby}" -c "#{f.path}" 2>&1`
    f.close!
    out.include?('Syntax OK')
  end
end
