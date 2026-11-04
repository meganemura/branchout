# frozen_string_literal: true

require "branchout/coverage"
require_relative "active_record"
require_relative "pantry"

module PantryHelpers
  def owner = "ada"
end

RSpec.configure do |config|
  config.include PantryHelpers
  config.around do |example|
    rows = ActiveRecord::Base.rows.dup
    example.run
    ActiveRecord::Base.rows.replace(rows)
  end
end
