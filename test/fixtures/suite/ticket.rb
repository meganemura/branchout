# frozen_string_literal: true

require "securerandom"

# A model method whose result holds a value each run makes anew, as a
# record's generated id or a SecureRandom token is.
class Ticket
  def self.attributes_from(part, line: nil)
    raise ArgumentError, "no part" if part.nil?

    attributes = {part: part, token: SecureRandom.hex(4)}
    attributes[:line] = line if line
    attributes
  end

  def self.code = "T-#{SecureRandom.hex(2)}"

  def self.stocked(sku) = ActiveRecord::Base.rows.any? { |row| row.last == sku } ? :stocked : :missing
end
