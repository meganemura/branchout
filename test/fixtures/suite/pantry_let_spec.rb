# frozen_string_literal: true

require "spec_helper"
require "branchout"

RSpec.describe Pantry do
  let(:cook) { "cy" }

  it "explores stock with an input that reads a let" do
    cook
    Branchout.explore("Pantry#stock", within: self, inputs: [
      {receiver: {ruby: "Pantry.new(owner)"}, args: ["jam"]},
      {receiver: {ruby: "Pantry.new(cook)"}, args: ["tea"]}
    ])
  end
end
