# frozen_string_literal: true

require "test_helper"
require "branchout"

class PantryRestockExploreTest < SuiteCase
  def test_explore
    rows = ActiveRecord::Base.rows.dup
    around = {
      "run_only" => Branchout::RUN_ONLY,
      "custom" => ->(&input) { input.call },
      "wrapped" => ->(&input) { Branchout::ROLL_BACK.call(&input) }
    }[ENV["BRANCHOUT_AROUND"]]
    report = Branchout.explore("Pantry#restock", within: self, around: around, emit_tests: ENV.fetch("EMIT_TO"), format: :minitest, inputs: [
      {receiver: {ruby: "Pantry.new(owner)"}, args: ["jam"]}
    ])
    File.write(ENV.fetch("REPORT_TO"), "#{report}rows left: #{ActiveRecord::Base.rows.length - rows.length}\n")
  end
end
