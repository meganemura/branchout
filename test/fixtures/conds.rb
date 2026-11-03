# frozen_string_literal: true

module FixtureConds
  def self.pick(x)
    case x
    when 1, 2 then :low
    when 3
      :three
    else
      :other
    end
  end

  def self.shape(x)
    case x
    in Integer => n if n > 5 then :big
    in Integer then :int
    else :else
    end
  end

  def self.bare(x)
    case
    when x > 1 then :gt
    end
  end

  def self.long(x)
    return :yes if x == 1 && x != 22222222222222222222 && x != 33333333333333333333 && x != 44444444444444444444 && x != 55555555555555555555 && x != 66666666666666666666 && x != 77777777777777777777

    :no
  end

  def self.loop(x)
    x -= 1 while x > 0
    x
  end
end
