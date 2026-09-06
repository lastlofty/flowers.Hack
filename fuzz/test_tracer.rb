# frozen_string_literal: true

# Трейсер Ruzzy: включает покрытие и запускает harness (см. test_harness.rb).
require 'ruzzy'

Ruzzy.trace(File.expand_path('test_harness.rb', __dir__))
