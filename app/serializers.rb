# frozen_string_literal: true

module Paybridge
  module Serializers
    module_function

    def integration(model)
      {
        id: model.id,
        provider: model.provider,
        status: model.status,
        endpoints: model.endpoints,
        files: model.files,
        warnings: model.warnings,
        valid: model.valid,
        syntax_error: model.syntax_error,
        created_at: model.created_at,
        verification: model.verification
      }
    end

    def verification(report)
      report.to_h
    end
  end
end
