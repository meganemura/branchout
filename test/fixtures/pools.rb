# frozen_string_literal: true

module FixturePools
  def self.mix(rate, count = 7, label:, flag: false)
    if rate > 2.5 && count == 3
      :hit
    elsif label == "x" || flag
      :label
    else
      :miss
    end
  end
end
