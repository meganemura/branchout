# frozen_string_literal: true

module FixtureReview
  def self.rate(rate, note)
    return :invalid unless rate.is_a?(Numeric)
    label = note&.strip
    if rate > 10
      :high
    elsif rate.zero?
      label ? :zero_noted : :zero
    else
      :low
    end
  end

  def self.count(n)
    n -= 1 while n > 3
    n
  end
end
