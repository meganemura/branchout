# frozen_string_literal: true

require "branchout/coverage"
require "dot_helper"
require "branchout"

RSpec.describe Pantry do
  it "explores stock" do
    warn "branchout/coverage from #{$LOADED_FEATURES.grep(%r{/branchout/coverage\.rb\z}).first}"
    puts Branchout.explore("Pantry#stock", within: self, inputs: [{receiver: {ruby: "Pantry.new('ada')"}, args: ["jam"]}])
  end
end
