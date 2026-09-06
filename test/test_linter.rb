# frozen_string_literal: true

require 'minitest/autorun'
require 'yaml'
require_relative '../lib/paybridge'

# Python-модуль структурного линта OpenAPI (многоязычность как доп. идея).
# Тесты работают против реального Python, если он доступен; иначе проверяют
# корректную деградацию (skipped).
class TestLinter < Minitest::Test
  def lint(doc)
    Paybridge::Linter.lint(doc)
  end

  def valid_spec
    YAML.safe_load(
      File.read(File.expand_path('../examples/provider_api.yaml', __dir__)), aliases: true
    )
  end

  def op(**over)
    { 'openapi' => '3.0.3', 'info' => { 'title' => 'T', 'version' => '1' } }.merge(over)
  end

  def test_graceful_without_python
    skip 'python доступен — проверяется реальный линт' if Paybridge::Linter.available?
    assert lint(op)['skipped']
  end

  def test_valid_spec_passes
    skip 'python недоступен' unless Paybridge::Linter.available?
    report = lint(valid_spec)
    assert report['valid'], report['errors'].inspect
  end

  def test_paths_not_object
    skip 'python недоступен' unless Paybridge::Linter.available?
    report = lint(op('paths' => 'nope'))
    refute report['valid']
    assert(report['errors'].any? { |e| e['message'].include?('paths') })
  end

  def test_unresolved_ref
    skip 'python недоступен' unless Paybridge::Linter.available?
    doc = op('paths' => { '/x' => { 'post' => {
               'responses' => { '200' => { 'description' => 'ok', 'content' => {
                 'application/json' => { 'schema' => { '$ref' => '#/components/schemas/Nope' } }
               } } }
             } } })
    report = lint(doc)
    refute report['valid']
    assert(report['errors'].any? { |e| e['message'].include?('$ref') })
  end

  def test_security_missing_scheme
    skip 'python недоступен' unless Paybridge::Linter.available?
    doc = op('paths' => { '/x' => { 'post' => {
               'security' => [{ 'Missing' => [] }],
               'responses' => { '200' => { 'description' => 'ok' } }
             } } })
    report = lint(doc)
    refute report['valid']
    assert(report['errors'].any? { |e| e['message'].include?('security') })
  end

  def test_swagger2_rejected
    skip 'python недоступен' unless Paybridge::Linter.available?
    report = lint('swagger' => '2.0', 'info' => { 'title' => 'T', 'version' => '1' }, 'paths' => {})
    refute report['valid']
  end
end
