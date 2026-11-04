# frozen_string_literal: true

require "test_helper"
require "minitest/spec"
require "branchout"

describe Pantry do
  let(:cook) { "cy" }

  it "explores stock again after an explore that was refused" do
    begin
      Branchout.explore("Pantry#stock", within: self, inputs: [{receiver: {ruby: "Pantry.new(cook)"}, args: ["tea"]}])
    rescue Branchout::Error
      nil
    end
    full = "ActiveRecord::Base.rows.push([1], [2]); Pantry.new('bo')"
    print Branchout.explore("Pantry#stock", within: self, inputs: [{receiver: {ruby: full}, args: ["salt"]}])
  end
end
