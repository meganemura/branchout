# frozen_string_literal: true

# A suite as an app's test helper starts one: coverage first, then the
# test framework, then the app, whose rows live in a store that a fake
# ActiveRecord rolls back.
require "branchout/coverage"
require "minitest/autorun"
require_relative "active_record"
require_relative "pantry"
require_relative "ticket"

# Each test's rows are undone after it, as a transactional test does.
class SuiteCase < Minitest::Test
  def setup = @rows = ActiveRecord::Base.rows.dup

  def teardown = ActiveRecord::Base.rows.replace(@rows)

  def owner = "ada"

  # A new value on each call, as a factory sequence gives.
  def serial = "L-#{SecureRandom.hex(3)}"
end
