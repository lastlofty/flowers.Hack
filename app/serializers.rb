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
        created_at: model.created_at
      }
    end

    def verification(report)
      {
        passed: report.passed,
        failed: report.failed,
        cases: report.cases.map do |test_case|
          { name: test_case.name, ok: test_case.ok, detail: test_case.detail }
        end
      }
    end
  end
end
