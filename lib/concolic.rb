# frozen_string_literal: true

require "json"
require "pathname"
require "stringio"
require "timeout"

module Concolic
  VERSION = "0.1.0"
  Error = Class.new(StandardError)
end

require_relative "concolic/canon"
require_relative "concolic/rng"
require_relative "concolic/input"
require_relative "concolic/input_file"
require_relative "concolic/target"
require_relative "concolic/runner"
require_relative "concolic/mutator"
require_relative "concolic/sampler"
require_relative "concolic/engine"
require_relative "concolic/report"
require_relative "concolic/characterize"
require_relative "concolic/cli"
