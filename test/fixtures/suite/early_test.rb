# frozen_string_literal: true

# A suite whose coverage starts too late or belongs to another tool.
require "coverage"
Coverage.start(lines: true) if ENV["COVERAGE_TOOL"]
require_relative "pantry" if ENV["PANTRY_FIRST"]
require "test_helper"
require "branchout"

class EarlyTest < SuiteCase
  def test_explore
    Branchout.explore("Pantry#stock", within: self, inputs: [{receiver: {ruby: "Pantry.new(owner)"}, args: ["jam"]}])
  end
end
