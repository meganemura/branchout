# frozen_string_literal: true

class FixtureBox
  def parity(n)
    if n.even?
      :even
    else
      :odd
    end
  end
end
