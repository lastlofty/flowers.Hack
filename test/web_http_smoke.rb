# frozen_string_literal: true
# Run against a locally started server. Uses real HTTP and the real generator.
require 'net/http'
require 'json'
require 'stringio'
require 'zip'

origin = ARGV.first || 'http://127.0.0.1:9292'
base = URI(origin)
abort 'Smoke test accepts only a loopback server' unless %w[localhost 127.0.0.1 ::1].include?(base.host)
checks = 0
assert = lambda do |condition, label|
  raise label unless condition
  checks += 1
end
request = lambda do |method, path, spec = nil, provider = nil|
  uri = URI.join(origin, path)
  req = method == :post ? Net::HTTP::Post.new(uri) : Net::HTTP::Get.new(uri)
  if spec
    File.open(spec, 'rb') do |file|
      req.set_form([['spec', file, { filename: File.basename(spec), content_type: 'application/x-yaml' }], ['provider', provider]], 'multipart/form-data')
      Net::HTTP.start(uri.host, uri.port, read_timeout: 30) { |http| http.request(req) }
    end
  else
    Net::HTTP.start(uri.host, uri.port, read_timeout: 30) { |http| http.request(req) }
  end
end
health = JSON.parse(request.call(:get, '/api/health').body)
assert.call(health['status'] == 'ok', 'health')
assert.call([true, false].include?(health['verification_available']), 'verification capability')
%w[/ /app.js /app.css /ui-core.mjs /favicon.svg].each do |path|
  response = request.call(:get, path)
  assert.call(response.code == '200', "asset #{path}")
  assert.call(response.content_type.include?('javascript'), "module MIME #{path}") if path.end_with?('.mjs', '.js')
end
{
  'novapay' => 'provider_api.yaml', 'bluepay' => 'bluepay_api.yaml',
  'swiftpay' => 'swiftpay_api.yaml', 'europay' => 'europay_api.yaml'
}.each do |provider, filename|
  spec = File.expand_path("../examples/#{filename}", __dir__)
  parsed = request.call(:post, '/api/validate', spec, provider)
  assert.call(parsed.code == '200', "validate #{provider}")
  model = JSON.parse(parsed.body)
  assert.call(!model['endpoints'].empty?, "endpoints #{provider}")
  assert.call(model['provider'] == provider, "provider #{provider}")
  generated = request.call(:post, '/api/integrations', spec, provider)
  assert.call(generated.code == '201', "generate #{provider}")
  integration = JSON.parse(generated.body)
  assert.call(integration['valid'] == true, "syntax #{provider}")
  assert.call(integration['files'].size == 5, "files #{provider}")
  prefix = "/api/integrations/#{integration['id']}"
  integration['files'].each do |name|
    response = request.call(:get, "#{prefix}/files/#{name}")
    assert.call(response.code == '200' && !response.body.empty?, "download #{name}")
  end
  archive = request.call(:get, "#{prefix}/archive")
  names = []
  Zip::InputStream.open(StringIO.new(archive.body)) do |zip|
    while (entry = zip.get_next_entry)
      names << entry.name
    end
  end
  assert.call(names.sort == integration['files'].sort, "ZIP contents #{provider}")
  blocked = request.call(:post, "#{prefix}/verify")
  if health['verification_available']
    report = JSON.parse(blocked.body)
    assert.call(blocked.code == '200' && report['passed'].to_i.positive? && report['failed'] == 0, "container verify #{provider}")
  else
    assert.call(blocked.code == '503' && JSON.parse(blocked.body).dig('error', 'code') == 'verification_unavailable', "safe verify #{provider}")
  end
end
assert.call(request.call(:post, '/api/integrations').code == '400', 'missing file')
assert.call(request.call(:get, '/api/integrations/missing').code == '404', 'missing integration')
puts "#{checks} HTTP checks passed against #{origin}; no mocks."
