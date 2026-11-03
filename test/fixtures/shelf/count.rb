# frozen_string_literal: true

module FixtureShelf
  def self.full?(books)
    books.length >= LIMIT ? :full : :room
  end
end
