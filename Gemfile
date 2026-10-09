# frozen_string_literal: true

source 'https://rubygems.org'

# Dylan uses Ruby 4 features throughout: `it` block parameter (3.4+) and
# RubyVM::ZJIT (4.0+). Declared here so a wrong local Ruby fails with a
# clear Bundler message instead of a NameError deep in server.rb.
ruby '~> 4.0'

# Async HTTP Server
gem 'async', '~> 2.0'
gem 'async-http', '~> 0.60'
gem 'protocol-http', '~> 0.25'

# minitest is a bundled gem since Ruby 3.4: under `bundle exec` it only loads
# when the Gemfile names it. The image skips this group (see Dockerfile).
group :test do
  gem 'minitest', '~> 6.0'
end
