# frozen_string_literal: true

require 'rake/testtask'

Rake::TestTask.new(:test) do |t|
  t.libs << 'lib' << 'test'
  t.test_files = FileList['test/**/test_*.rb']
  t.warning = false
end

desc 'Прогнать генератор на примере (по умолчанию NovaPay)'
task :demo, [:spec, :provider] do |_t, args|
  spec = args[:spec] || 'examples/provider_api.yaml'
  provider = args[:provider] || 'novapay'
  ruby "exe/integrate --spec #{spec} --provider #{provider}"
end

desc 'Coverage-guided фаззинг генератора (по умолчанию 4000 итераций)'
task :fuzz, [:iterations] do |_t, args|
  ruby "tools/fuzz_generator.rb #{args[:iterations] || 4000}"
end

task default: :test
