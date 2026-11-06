# frozen_string_literal: true

require "date"
require "securerandom"

# A model method whose result holds an id the database makes anew on each
# run beside a Date the input passed, as a record's attributes do.
module Stamp
  def self.attributes_from(code, start_at)
    raise KeyError, "no part" unless code == "A"

    {name: "n", part_id: SecureRandom.uuid, start_at: start_at, end_at: nil}
  end

  def self.token(code, token = SecureRandom.hex(4))
    raise KeyError, "no part" unless code == "A"

    token
  end
end
