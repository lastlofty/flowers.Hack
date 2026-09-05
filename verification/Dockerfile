FROM ruby:3.3-slim
WORKDIR /runner
COPY lib/paybridge/verifier.rb /runner/verifier.rb
COPY verification/worker.rb /runner/worker.rb
USER 65534:65534
CMD ["ruby", "/runner/worker.rb"]
