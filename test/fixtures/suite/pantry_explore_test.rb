# frozen_string_literal: true

require "test_helper"
require "branchout"

class PantryExploreTest < SuiteCase
  def test_explore
    around = ENV["BRANCHOUT_AROUND"] == "run_only" ? Branchout::RUN_ONLY : nil
    rows = ActiveRecord::Base.rows.dup
    report = Branchout.explore("Pantry#stock", within: self, around: around, verbose: true, emit_tests: ENV.fetch("EMIT_TO"), format: :minitest, inputs: [
      {receiver: {ruby: "Pantry.new(owner)"}, args: ["jam"]},
      {receiver: {ruby: "Pantry.new(owner)"}, args: [{ruby: "pantry.owner + ' tea'"}]},
      {receiver: {ruby: "Pantry.new('bo')"}, args: ["salt"]}
    ])
    File.write(ENV.fetch("REPORT_TO"), "#{report}rows left: #{ActiveRecord::Base.rows.length - rows.length}\n")
  end
end
