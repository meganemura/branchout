# frozen_string_literal: true

require "spec_helper"
require "branchout"

RSpec.describe Pantry, type: :model do
  it "explores stock" do
    report = Branchout.explore("Pantry#stock", within: self, timeout: nil, verbose: true, emit_tests: ENV.fetch("EMIT_TO"), inputs: [
      {receiver: {ruby: "Pantry.new(owner)"}, args: ["jam"]},
      {receiver: {ruby: "Pantry.new(owner)"}, args: [{ruby: "pantry.owner + ' tea'"}]},
      {receiver: {ruby: "Pantry.new('bo')"}, args: ["salt"]}
    ])
    File.write(ENV.fetch("REPORT_TO"), report)
  end
end
