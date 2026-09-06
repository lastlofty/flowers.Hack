# frozen_string_literal: true

# (Пере)генерирует эталонный вывод (golden files) для примеров провайдеров.
# Запуск:  rake golden   (или ruby tools/golden.rb)
# Тест test/test_golden.rb сверяет генерацию с этими файлами байт-в-байт.
require_relative '../lib/paybridge'
require 'fileutils'

PROVIDERS = [
  ['examples/provider_api.yaml', 'novapay'],
  ['examples/bluepay_api.yaml',  'bluepay'],
  ['examples/swiftpay_api.yaml', 'swiftpay'],
  ['examples/europay_api.yaml',  'europay']
].freeze

GOLDEN = File.expand_path('../test/golden', __dir__)

PROVIDERS.each do |spec, provider|
  gen = Paybridge.generate(spec_path: spec, provider: provider)
  dir = File.join(GOLDEN, provider)
  FileUtils.mkdir_p(dir)
  gen.files.each { |name, body| File.binwrite(File.join(dir, name), body) }
  puts "golden: #{provider} — #{gen.files.size} файлов"
end

puts "Готово. Эталон в #{GOLDEN}"
