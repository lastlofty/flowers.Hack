# Воспроизводимый запуск Ruzzy (libFuzzer) для PayBridge на Linux.
# Ruzzy поддерживает только Linux/macOS + clang, поэтому фаззинг гоняем в контейнере.
#
#   docker build -f fuzz/Dockerfile -t paybridge-fuzz .
#   docker run --rm -it paybridge-fuzz            # бесконечный фаззинг
#   docker run --rm -it paybridge-fuzz -runs=100000   # ограниченный прогон
FROM ruby:3.3-bookworm

RUN apt-get update && apt-get install -y --no-install-recommends clang && \
    rm -rf /var/lib/apt/lists/*

ENV CC=clang CXX=clang++
RUN MAKE="make --environment-overrides V=1" \
    CC="clang" CXX="clang++" \
    LDSHARED="clang -shared" LDSHAREDXX="clang++ -shared" \
    gem install ruzzy

WORKDIR /app
COPY . /app

ENV ASAN_OPTIONS="allocator_may_return_null=1:detect_leaks=0:use_sigaltstack=0"

# LD_PRELOAD подгружает ASAN; сид-корпус — fuzz/corpus.
ENTRYPOINT ["bash", "-lc", "LD_PRELOAD=$(ruby -e 'require \"ruzzy\"; print Ruzzy::ASAN_PATH') ruby fuzz/test_tracer.rb fuzz/corpus \"$@\"", "--"]
