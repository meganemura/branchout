# frozen_string_literal: true

module FixtureHelpers
  def self.plain(x) = x

  module_function

  def sign(x)
    x.positive? ? :positive : bucket(x)
  end

  def bucket(x)
    x.zero? ? :zero : :negative
  end
end

module FixtureNamed
  def twice(x) = x > 3 ? :big : :small
  module_function :twice
end
