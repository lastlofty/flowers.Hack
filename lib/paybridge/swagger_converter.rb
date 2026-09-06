# frozen_string_literal: true

module Paybridge
  # Нормализует Swagger 2.0 в структуру, которую понимает наш парсер (OpenAPI 3.x):
  # servers, requestBody, responses.content, components.schemas/securitySchemes и
  # переписанные $ref. Применяется на входе — дальше работает единый 3.x-путь.
  #
  # Только реструктуризация уже разобранного YAML (Hash) — без исполнения.
  module SwaggerConverter
    module_function

    def swagger2?(doc)
      doc.is_a?(Hash) && doc['swagger'].to_s.start_with?('2')
    end

    # Мутирует и возвращает doc, приведённый к OpenAPI 3.x. Не-Swagger — без изменений.
    def convert(doc)
      return doc unless swagger2?(doc)

      rewrite_refs!(doc)          # #/definitions/X -> #/components/schemas/X
      convert_servers!(doc)       # host+basePath+schemes -> servers
      convert_paths!(doc)         # body-param -> requestBody, responses -> content
      move_components!(doc)       # definitions/securityDefinitions -> components
      doc['openapi'] = '3.0.0'
      doc.delete('swagger')
      doc
    end

    def rewrite_refs!(node)
      case node
      when Hash
        ref = node['$ref']
        node['$ref'] = ref.sub('#/definitions/', '#/components/schemas/') if ref.is_a?(String) && ref.start_with?('#/definitions/')
        node.each_value { |value| rewrite_refs!(value) }
      when Array
        node.each { |value| rewrite_refs!(value) }
      end
    end

    def convert_servers!(doc)
      unless doc['servers']
        host = doc['host']
        if host
          schemes = doc['schemes'].is_a?(Array) ? doc['schemes'] : ['https']
          scheme = schemes.include?('https') ? 'https' : (schemes.first || 'https')
          doc['servers'] = [{ 'url' => "#{scheme}://#{host}#{doc['basePath']}" }]
        end
      end
      %w[host basePath schemes consumes produces].each { |key| doc.delete(key) }
    end

    def convert_paths!(doc)
      paths = doc['paths']
      return unless paths.is_a?(Hash)

      paths.each_value do |item|
        next unless item.is_a?(Hash)

        item.each do |method, op|
          convert_operation!(op) if %w[get post put patch delete].include?(method)
        end
      end
    end

    def convert_operation!(op)
      return unless op.is_a?(Hash)

      params = op['parameters']
      if params.is_a?(Array)
        body = params.find { |p| p.is_a?(Hash) && p['in'] == 'body' && p['schema'] }
        if body
          op['requestBody'] = {
            'required' => body['required'] ? true : false,
            'content' => { 'application/json' => { 'schema' => body['schema'] } }
          }
        end
        op['parameters'] = params
                           .reject { |p| p.is_a?(Hash) && %w[body formData].include?(p['in']) }
                           .map { |p| convert_param(p) }
      end
      convert_responses!(op['responses'])
    end

    # Swagger-параметр держит type/format прямо на себе; OpenAPI 3 — внутри schema.
    def convert_param(param)
      return param unless param.is_a?(Hash)
      return param if param.key?('schema') || param.key?('$ref')

      schema_keys = %w[type format enum items minimum maximum pattern]
      schema = param.select { |key, _| schema_keys.include?(key) }
      rest = param.reject { |key, _| schema_keys.include?(key) }
      rest['schema'] = schema unless schema.empty?
      rest
    end

    def convert_responses!(responses)
      return unless responses.is_a?(Hash)

      responses.each_value do |resp|
        next unless resp.is_a?(Hash)

        media = {}
        media['schema'] = resp.delete('schema') if resp['schema']
        examples = resp.delete('examples')
        if examples.is_a?(Hash)
          value = examples['application/json'] || examples.values.first
          media['example'] = value unless value.nil?
        end
        resp['content'] = { 'application/json' => media } unless media.empty?
      end
    end

    def move_components!(doc)
      components = (doc['components'] ||= {})
      components['schemas'] = doc.delete('definitions') if doc['definitions'].is_a?(Hash)
      return unless doc['securityDefinitions'].is_a?(Hash)

      components['securitySchemes'] = doc.delete('securityDefinitions')
                                         .transform_values { |scheme| convert_security(scheme) }
    end

    # Swagger basic -> OpenAPI http/basic; apiKey совпадает; oauth2 оставляем как есть
    # (парсер честно предупредит, что схема не поддержана).
    def convert_security(scheme)
      return scheme unless scheme.is_a?(Hash)

      scheme['type'] == 'basic' ? { 'type' => 'http', 'scheme' => 'basic' } : scheme
    end
  end
end
