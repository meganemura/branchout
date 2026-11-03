# frozen_string_literal: true

require "json"
require "pathname"
require "stringio"
require "timeout"

module Branchout
  VERSION = "0.1.0"
  Error = Class.new(StandardError)
end

require_relative "branchout/canon"
require_relative "branchout/rng"
require_relative "branchout/input"
require_relative "branchout/input_file"
require_relative "branchout/target"
require_relative "branchout/runner"
require_relative "branchout/mutator"
require_relative "branchout/sampler"
require_relative "branchout/engine"
require_relative "branchout/report"
require_relative "branchout/emitters"
require_relative "branchout/cli"
