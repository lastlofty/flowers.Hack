# frozen_string_literal: true

require 'minitest/autorun'
require 'yaml'
require 'tmpdir'
require 'open3'
require 'rbconfig'
require 'fileutils'
require_relative '../lib/paybridge'

class TestCriticalGeneration < Minitest::Test
  def document
    YAML.safe_load(File.read(File.expand_path('../examples/provider_api.yaml', __dir__)), aliases: true)
  end

  def generated(doc)
    Dir.mktmpdir('critical_generation_') do |dir|
      path = File.join(dir, 'source.yaml')
      File.write(path, YAML.dump(doc))
      generation = Paybridge.generate(spec_path: path, provider: 'criticalpay')
      generation.files.each { |name, content| File.write(File.join(dir, name), content) }
      FileUtils.cp(Paybridge::BASE_SERVICE, File.join(dir, 'base_service.rb'))
      yield dir, generation
    end
  end

  # Only harmless marker payloads in these tests. Run generated code in a
  # fresh subprocess so class constants cannot leak between test cases.
  def run_service(dir, body)
    script = <<~RUBY
      require #{File.join(dir, 'base_service.rb').inspect}
      require #{File.join(dir, 'criticalpay_service.rb').inspect}
      service = Provider::CriticalpayService.new(provider: Struct.new(:credentials).new({}))
      operation = Struct.new(:amount, :id, :payout_requisite, :idempotency_key).new(1024.09, 'op', {}, 'idem')
      #{body}
      abort 'injected marker executed' if Provider::CriticalpayService.const_defined?(:AUDIT_MARKER, false)
    RUBY
    out, err, status = Open3.capture3(RbConfig.ruby, '-e', script)
    assert status.success?, "#{out}\n#{err}"
  end

  def test_currency_is_preserved_as_data
    doc = document
    currency = "RUB' + (AUDIT_MARKER = 12345).to_s + '\\\n\#{literal}"
    doc['components']['schemas']['CreatePayoutRequest']['properties']['currency']['enum'] = [currency]
    generated(doc) do |dir, _|
      run_service(dir, "actual = service.send(:build_request_payload, operation)[:currency]; abort actual.inspect unless actual == #{currency.dump}")
    end
  end

  def test_method_and_required_field_names_remain_data
    doc = document
    method = "sbp] ; AUDIT_MARKER = 12345; %w[sbp"
    field = "field] ; AUDIT_MARKER = 67890; %w[field"
    recipient = doc['components']['schemas']['Recipient']
    recipient['properties']['type']['enum'] = [method, 'card']
    recipient['properties'][field] = { 'type' => 'string' }
    recipient['required'] << field
    generated(doc) do |dir, _|
      run_service(dir, <<~RUBY)
        abort 'method changed' unless Provider::CriticalpayService::PAYOUT_METHODS == #{[method, 'card'].inspect}
        abort 'field changed' unless Provider::CriticalpayService::REQUIRED_REQUISITE.fetch(#{method.dump}).include?(#{field.dump})
        operation.payout_requisite = {#{method.dump} => {#{field.dump} => 'test'}}
        result = service.send(:build_request_payload, operation, #{method.dump})
        abort 'request field changed' unless result[:recipient][#{field.dump}] == 'test'
      RUBY
    end
  end

  def test_non_numeric_minimum_is_rejected
    ['0; AUDIT_MARKER = 12345', '100', nil, true, [], {}, Float::INFINITY, Float::NAN].each do |minimum|
      doc = document
      doc['components']['schemas']['CreatePayoutRequest']['properties']['amount']['minimum'] = minimum
      error = assert_raises(Paybridge::GenerationError) { generated(doc) { flunk 'invalid minimum accepted' } }
      assert_match(/minimum/, error.message)
    end
  end

  def test_minor_units_are_exact_for_float_decimal_string_and_bigdecimal
    generated(document) do |dir, _|
      run_service(dir, <<~'RUBY')
        [[1.13,113], [1024.09,102409], ['1024.09',102409], [BigDecimal('1024.09'),102409],
         [1000,100000], ['0.005',1], ['1.125',113], ['999.994',99999], ['999.995',100000]].each do |value, expected|
          operation.amount = value
          operation.payout_requisite = {'sbp'=>{'phone'=>'1','bank_code'=>'2'}}
          actual = service.send(:build_request_payload, operation)[:amount]
          abort "#{value.inspect}: #{actual} != #{expected}" unless actual == expected
          result = service.check_conditions(operation, 'sbp')
          abort 'minimum and request disagree' unless result.success? == (expected >= 100000)
        end
        [Float::INFINITY, Float::NAN, nil, 'bad'].each do |value|
          begin
            service.send(:amount_in_minor_units, value)
            abort 'invalid amount accepted'
          rescue ArgumentError
          end
        end
      RUBY
    end
  end
end
