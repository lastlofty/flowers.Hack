# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'json'
require_relative '../lib/paybridge'

# CLI dump-ir (дамп IR) и resolve (вопросы + заготовка решений) — прозрачность и
# сбор недостающих данных, аналог program.mir/resolve у конкурентов.
class TestDumpIrAndResolve < Minitest::Test
  def spec(rel) = File.expand_path("../examples/#{rel}", __dir__)

  def run_cli(args)
    code = nil
    out = capture_io { code = Paybridge::CLI.start(args) }
    [code, out.join]
  end

  def test_dump_ir_writes_full_ir
    Dir.mktmpdir('pb_ir_') do |dir|
      code, = run_cli(['dump-ir', '--spec', spec('provider_api.yaml'), '--provider', 'novapay', '--output', dir])
      assert_equal 0, code
      ir = JSON.parse(File.read(File.join(dir, 'novapay.ir.json')))
      assert_equal 'POST /payouts', ir.dig('recognized', 'create')
      assert_operator ir.dig('endpoints', 0, 'spec_line'), :>, 0
      assert ir['request_payload_ruby'].is_a?(String)
      assert ir.key?('status_map')
    end
  end

  def test_resolve_clean_spec_has_no_questions
    code, out = run_cli(['resolve', '--spec', spec('provider_api.yaml'), '--provider', 'novapay'])
    assert_equal 0, code
    assert_includes out, 'вопросов нет'
  ensure
    File.delete('decisions.yml') if File.exist?('decisions.yml')
  end

  def test_resolve_manual_fields_produces_questions_and_lock
    Dir.mktmpdir('pb_res_') do |dir|
      lock = File.join(dir, 'decisions.yml')
      code, out = run_cli(['resolve', '--spec', spec('manualpay_api.yaml'), '--provider', 'manualpay', '--lock', lock])
      assert_equal 1, code # не выпущено, пока не решено
      assert_includes out, 'Требуются решения'
      assert_includes out, 'merchant_category'
      assert File.file?(lock)
      body = File.read(lock)
      assert_includes body, 'amount_unit'
      assert_includes body, 'merchant_category'
    end
  end
end
