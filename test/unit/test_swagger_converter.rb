# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../lib/paybridge/swagger_converter'

class TestSwaggerConverter < Minitest::Test
  def convert(doc) = Paybridge::SwaggerConverter.convert(doc)

  def test_non_swagger_untouched
    doc = { 'openapi' => '3.0.0', 'paths' => {} }
    assert_same doc, convert(doc)
    assert_equal '3.0.0', doc['openapi']
  end

  def test_servers_from_host
    doc = convert('swagger' => '2.0', 'host' => 'api.x.com', 'basePath' => '/v2', 'schemes' => ['https'])
    assert_equal 'https://api.x.com/v2', doc.dig('servers', 0, 'url')
    assert_equal '3.0.0', doc['openapi']
    refute doc.key?('swagger')
    refute doc.key?('host')
  end

  def test_body_param_to_request_body_and_ref_rewrite
    doc = convert(
      'swagger' => '2.0',
      'paths' => { '/p' => { 'post' => {
        'parameters' => [{ 'in' => 'body', 'required' => true, 'schema' => { '$ref' => '#/definitions/Req' } }],
        'responses' => { '201' => { 'schema' => { '$ref' => '#/definitions/Res' },
                                    'examples' => { 'application/json' => { 'id' => 'x' } } } }
      } } },
      'definitions' => { 'Req' => { 'type' => 'object' } }
    )
    op = doc.dig('paths', '/p', 'post')
    assert_equal '#/components/schemas/Req', op.dig('requestBody', 'content', 'application/json', 'schema', '$ref')
    assert_equal '#/components/schemas/Res', op.dig('responses', '201', 'content', 'application/json', 'schema', '$ref')
    assert_equal({ 'id' => 'x' }, op.dig('responses', '201', 'content', 'application/json', 'example'))
    assert doc.dig('components', 'schemas', 'Req')
    refute doc.key?('definitions')
  end

  def test_basic_security_becomes_http
    doc = convert('swagger' => '2.0', 'securityDefinitions' => { 'B' => { 'type' => 'basic' } })
    scheme = doc.dig('components', 'securitySchemes', 'B')
    assert_equal 'http', scheme['type']
    assert_equal 'basic', scheme['scheme']
  end
end
