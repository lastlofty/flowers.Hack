# frozen_string_literal: true

require 'minitest/autorun'
require 'tempfile'
require_relative '../lib/paybridge'

# P1 §9: некорректные разделы спеки -> понятная GenerationError (API -> 422).
class TestParserValidation < Minitest::Test
  def generate(yaml)
    f = Tempfile.new(['s', '.yaml'])
    f.write(yaml)
    f.rewind
    Paybridge.generate(spec_path: f.path, provider: 'testpay')
  ensure
    f.close!
  end

  def test_paths_not_object_is_generation_error
    err = assert_raises(Paybridge::GenerationError) do
      generate(<<~YAML)
        openapi: 3.0.3
        info: { title: T, version: "1.0.0" }
        paths: invalid
      YAML
    end
    assert_match(/paths/i, err.message)
  end

  def test_swagger_2_rejected
    err = assert_raises(Paybridge::GenerationError) do
      generate(<<~YAML)
        swagger: "2.0"
        info: { title: T, version: "1.0.0" }
        paths: {}
      YAML
    end
    assert_match(/swagger|openapi/i, err.message)
  end
end
