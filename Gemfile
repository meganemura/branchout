# frozen_string_literal: true

source "https://rubygems.org"

gemspec

# hegeltest needs Ruby 3.4 or newer. On Ruby 3.3, install with
# BUNDLE_WITHOUT=property; test/test_properties.rb then skips.
group :property do
  gem "hegeltest", "0.5.1"
end

# rbs-inline writes sig/generated from the type comments in lib/, and steep
# checks lib/ against them.
group :types do
  gem "steep", "2.1.0", require: false
  gem "rbs-inline", "0.14.0", require: false
end
