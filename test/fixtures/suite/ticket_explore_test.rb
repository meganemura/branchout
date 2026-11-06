# frozen_string_literal: true

require "test_helper"
require "json"
require "branchout"

# Explores the entry in ENTRY on the inputs in INPUTS, a JSON list.
class TicketExploreTest < SuiteCase
  def test_explore
    puts Branchout.explore(ENV.fetch("ENTRY", "Ticket.attributes_from"), within: self, emit_tests: ENV["EMIT_TO"], format: :minitest,
                                                                        inputs: JSON.parse(ENV.fetch("INPUTS")))
  end
end
