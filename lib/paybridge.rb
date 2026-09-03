# frozen_string_literal: true

require 'yaml'
require 'fileutils'

require_relative 'paybridge/spec_parser'
require_relative 'paybridge/generators/service_generator'
require_relative 'paybridge/generators/docs_generator'
require_relative 'paybridge/generators/fixtures_generator'

module Paybridge
  VERSION = '0.1.0'

  ROOT           = File.expand_path('..', __dir__)
  DEFAULT_CONFIG = File.join(ROOT, 'config', 'mapping.yml')
  BASE_SERVICE   = File.join(__dir__, 'paybridge', 'templates', 'base_service.rb')

  module_function

  def load_config(path = DEFAULT_CONFIG)
    YAML.safe_load(File.read(path))
  end
end

require_relative 'paybridge/cli'
