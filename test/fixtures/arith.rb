# frozen_string_literal: true

module FixtureArith
  def self.classify(x, y)
    if (x * 3 + 7) % 1000 == 421
      if y == x + 5
        :both
      else
        :x_only
      end
    else
      :miss
    end
  end
end
