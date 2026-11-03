# frozen_string_literal: true

class FixtureDelegate
  def self.apply(x) = new.check(x)

  def check(x)
    x.positive? ? :yes : :no
  end
end
