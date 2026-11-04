# frozen_string_literal: true

require "test_helper"
require "branchout"

class PantryRestockExploreTest < SuiteCase
  def test_explore
    rows = ActiveRecord::Base.rows.dup
    report = Branchout.explore("Pantry#restock", within: self, emit_tests: ENV.fetch("EMIT_TO"), format: :minitest, inputs: [
      {receiver: {ruby: "Pantry.new(owner)"}, args: ["jam"]}
    ])
    File.write(ENV.fetch("REPORT_TO"), "#{report}rows left: #{ActiveRecord::Base.rows.length - rows.length}\n")
  end
end
