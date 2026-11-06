# frozen_string_literal: true

require "branchout/coverage"
require "branchout"

RSpec.describe Pantry do
  it "explores stock" do
    puts Branchout.explore("Pantry#stock", within: self, inputs: [{receiver: {ruby: "Pantry.new('ada')"}, args: ["jam"]}])
  end
end
