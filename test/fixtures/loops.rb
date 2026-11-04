# frozen_string_literal: true

module FixtureLoops
  def self.drain(n)
    until n <= 0
      n -= 1
    end
    n
  end

  def self.sign(h)
    if h.fetch(:x) > 0
      :pos
    else
      :neg
    end
  end

  def self.pick(s = "abc")
    s.length > 2 ? Integer(s) : s
  end
end
