# frozen_string_literal: true

module FixtureSpin
  def self.forever(n)
    while n > 0
      n += 1
    end
    :done
  end
end
