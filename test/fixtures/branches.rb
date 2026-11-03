# frozen_string_literal: true

module FixtureBranches
  def self.demo(s, n)
    label = case s
            when "a", "b"
              :ab
            when "c"
              :c
            else
              :other
            end
    while n > 0
      n -= 1
      label = :loop
    end
    label
  end
end
