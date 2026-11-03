# frozen_string_literal: true

module Arithmetic
  # (3x + 7) % 1000 == 421 is true for x = 138.
  # y == x + 5 then forces y = 143, and z == 7 is a third nested decision.
  # x == 114514 && x == 0 is unsatisfiable; that arm stays uncovered.
  def self.classify(x, y, z)
    if (x * 3 + 7) % 1000 == 421
      if y == x + 5
        if z == 7
          :hit
        else
          :need_z
        end
      else
        :x_only
      end
    elsif x == 114514 && x == 0
      :impossible
    else
      :miss
    end
  end
end
