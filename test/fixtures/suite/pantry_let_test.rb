# frozen_string_literal: true

require "test_helper"
require "minitest/spec"
require "branchout"

describe Pantry do
  let(:cook) { "cy" }

  it "explores stock with an input that reads a let" do
    Branchout.explore("Pantry#stock", within: self, inputs: [{receiver: {ruby: "Pantry.new(cook)"}, args: ["tea"]}])
  end
end
