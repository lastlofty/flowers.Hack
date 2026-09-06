# Фаззинг PayBridge

Два уровня фаззинга генератора. Контракт обоих: любой битый ввод должен давать
`Paybridge::GenerationError`, а не сырой краш (`NoMethodError`/`TypeError`/
`Psych`/`Encoding`/зависание).

## 1. Быстрый структурный фаззер (Ruby, без зависимостей)

Грейбокс coverage-guided (`Coverage` из stdlib): мутирует РАЗОБРАННУЮ спеку и
кормит генератор. Кроссплатформенный, гоняется где угодно:

```bash
rake fuzz            # 4000 итераций
ruby tools/fuzz_generator.rb 20000
```

## 2. Ruzzy / libFuzzer (байтовый, coverage-guided)

[Ruzzy](https://github.com/trailofbits/ruzzy) от Trail of Bits — настоящий
libFuzzer поверх Ruby. Кормит СЫРЫЕ байты, поэтому проверяет и уровень самого
YAML-парсера. Поддерживает **Linux/macOS + clang** (не Windows), поэтому удобнее
всего гонять в Docker:

```bash
docker build -f fuzz/Dockerfile -t paybridge-fuzz .
docker run --rm -it paybridge-fuzz -runs=200000
```

Или напрямую (Linux/macOS с clang):

```bash
MAKE="make --environment-overrides V=1" \
  CC=clang CXX=clang++ LDSHARED="clang -shared" LDSHAREDXX="clang++ -shared" \
  gem install ruzzy

export ASAN_OPTIONS="allocator_may_return_null=1:detect_leaks=0:use_sigaltstack=0"
LD_PRELOAD=$(ruby -e 'require "ruzzy"; print Ruzzy::ASAN_PATH') \
  ruby fuzz/test_tracer.rb fuzz/corpus
```

- `fuzz/test_harness.rb` — цель: байты -> спека -> `Paybridge.generate`.
- `fuzz/test_tracer.rb` — включает покрытие и запускает harness.
- `fuzz/corpus/` — сид-корпус (примеры спецификаций).

## Регрессии

Найденные фаззингом падения зафиксированы в `test/test_malformed_specs.rb`
(узлы не того типа, `!ruby/object`, неэкранированная дата, невалидный UTF-8).
Прогон: `rake test`.
