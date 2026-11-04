# frozen_string_literal: true

require "spec_helper"
require "branchout"

RSpec.describe Pantry do
  it "explores stock" do
    report = Branchout.explore("Pantry#stock", within: self, timeout: nil, emit_tests: ENV.fetch("EMIT_TO"), inputs: [
      {receiver: {ruby: "Pantry.new(owner)"}, args: ["jam"]},
      {receiver: {ruby: "Pantry.new(owner)"}, args: [{ruby: "pantry.owner + ' tea'"}]}
    ])
    File.write(ENV.fetch("REPORT_TO"), report)
  end
end
