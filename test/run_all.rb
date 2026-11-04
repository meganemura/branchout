# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "minitest/autorun"
# The CLI server forks before any test file loads a target.
require_relative "support/cli"
Dir[File.expand_path("test_*.rb", __dir__)].sort.each { |file| require file }
Dir[File.expand_path("generated/*_test.rb", __dir__)].sort.each { |file| require file }
