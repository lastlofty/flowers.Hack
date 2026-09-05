# frozen_string_literal: true

require 'json'
require_relative 'verifier'

# Keep normal service output away from the JSON protocol.
protocol = STDOUT.dup
STDOUT.reopen(STDERR)
begin
  report = Paybridge::Verifier.new('/input').run
  protocol.write(JSON.generate(cases: report.cases.map(&:to_h)))
rescue StandardError => e
  warn "#{e.class}: #{e.message}"
  exit 1
end
