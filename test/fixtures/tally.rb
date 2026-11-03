# frozen_string_literal: true

class FixtureTally
  def initialize
    @seen = 0
  end

  def bump(n)
    @seen += n
    if @seen > 3
      :over
    else
      :under
    end
  end
end
