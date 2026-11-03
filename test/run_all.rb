# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

Dir[File.expand_path("test_*.rb", __dir__)].sort.each { |file| require file }
