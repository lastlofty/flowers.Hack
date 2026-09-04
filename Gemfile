source 'https://rubygems.org'

ruby '>= 3.0'

# --- Ядро-генератор ---
# Использует только stdlib (psych, erb, optparse, json, openssl).
# Внешних рантайм-зависимостей у самого генератора нет.

# --- Веб-бэкенд (обёртка над генератором) ---
gem 'sinatra', '~> 4.0'      # веб-фреймворк (open source)
gem 'webrick', '~> 1.8'      # rack-сервер (pure Ruby, без нативной сборки)
gem 'rackup',  '~> 2.1'      # запуск rack-приложения
gem 'rubyzip', '~> 3.0'      # zip-архив с результатом

group :test do
  gem 'rake',      '~> 13.2'
  gem 'minitest',  '~> 5.20' # входит в stdlib, зафиксирована версия для CI
  gem 'rack-test', '~> 2.1'
end
