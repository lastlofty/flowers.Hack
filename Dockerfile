# Генератор интеграций PayBridge. Ядро использует только stdlib Ruby —
# внешних рантайм-зависимостей нет, поэтому образ минимальный и без bundle.
#
# Сборка:
#   docker build -t paybridge .
# Генерация (спека и результат монтируются с хоста):
#   docker run --rm -v "$PWD:/work" paybridge \
#     --spec /work/examples/provider_api.yaml --provider novapay --output /work/output
# Другие подкоманды:
#   docker run --rm -v "$PWD:/work" paybridge validate --spec /work/examples/provider_api.yaml --provider novapay
#   docker run --rm -v "$PWD:/work" paybridge diff --spec /work/examples/provider_api.yaml --provider novapay --dir /work/output
FROM ruby:3.2-slim

WORKDIR /app

# Только то, что нужно ядру-генератору (без веба и тестов).
COPY lib ./lib
COPY exe ./exe
COPY config ./config

RUN chmod +x exe/integrate

# exe/integrate — единая точка входа (generate по умолчанию; verify не включаем,
# т.к. изолированной проверке нужен свой Docker-раннер вне этого образа).
ENTRYPOINT ["ruby", "exe/integrate"]
CMD ["--help"]
