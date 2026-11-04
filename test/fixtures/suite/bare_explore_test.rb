# frozen_string_literal: true

# A suite with no helper file of a name explore knows.
require "branchout/coverage"
require "minitest/autorun"
require_relative "active_record"
require_relative "pantry"
require "branchout"

class BareExploreTest < Minitest::Test
  def test_explore
    Branchout.explore("Pantry#stock", within: self, emit_tests: ENV.fetch("EMIT_TO"), inputs: [{receiver: {ruby: "Pantry.new('ada')"}, args: ["jam"]}])
  end
end
