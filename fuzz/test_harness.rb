# frozen_string_literal: true

# Ruzzy (libFuzzer) harness для генератора PayBridge.
# https://github.com/trailofbits/ruzzy
#
# Кормит СЫРЫЕ байты фаззера как спецификацию провайдера. Контракт: любой битый
# ввод -> Paybridge::GenerationError. Любое ДРУГОЕ исключение пробрасывается —
# libFuzzer/AddressSanitizer фиксирует это как краш и минимизирует вход.
require 'ruzzy'
require 'tempfile'

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'paybridge'

def fuzzing_target(data)
  Tempfile.create(['ruzzy', '.yaml']) do |file|
    file.binmode
    file.write(data)
    file.flush
    begin
      Paybridge.generate(spec_path: file.path, provider: 'fuzzprov')
    rescue Paybridge::GenerationError
      # ожидаемо и корректно: контролируемая ошибка, не краш
    end
  end
end

test_one_input = lambda do |data|
  fuzzing_target(data)
  0
end

Ruzzy.fuzz(test_one_input)
