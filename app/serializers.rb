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
        created_at: model.created_at
      }
    end
  end
end
