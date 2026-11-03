# frozen_string_literal: true

module HiddenBug
  # ZeroDivisionError only when a > 10, b > 10, and a - b * 2 == 0.
  def self.scale(a, b)
    if a > 10 && b > 10
      denom = a - (b * 2)
      if denom < 50
        1000 / denom
      else
        :large_gap
      end
    else
      :out_of_range
    end
  end
end
