# frozen_string_literal: true

# A suite whose coverage starts too late or is started by another tool, as
# SimpleCov starts it from a helper before or after branchout/coverage.
require "coverage"
Coverage.start(lines: true) if ENV["COVERAGE_TOOL"] == "before"
require_relative "pantry" if ENV["PANTRY_FIRST"]
require "test_helper"
require "branchout"
Coverage.start(lines: true) if ENV["COVERAGE_TOOL"] == "after" && !Coverage.running?

class EarlyTest < SuiteCase
  def test_explore
    puts Branchout.explore("Pantry#stock", within: self, inputs: [{receiver: {ruby: "Pantry.new(owner)"}, args: ["jam"]}])
  end
end
