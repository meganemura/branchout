# frozen_string_literal: true

require "test_helper"
require "branchout"

# An after reads the rows the call wrote before the input's savepoint is
# rolled back, so its test pins what the call left.
class PantryAfterExploreTest < SuiteCase
  def test_explore
    report = Branchout.explore("Pantry#stock", within: self, emit_tests: ENV.fetch("EMIT_TO"), format: :minitest, inputs: [
      {receiver: {ruby: "Pantry.new(owner)"}, args: ["jam"], after: {ruby: "ActiveRecord::Base.rows.length"}}
    ])
    File.write(ENV.fetch("REPORT_TO"), "#{report}rows left: #{ActiveRecord::Base.rows.length - @rows.length}\n")
  end
end
