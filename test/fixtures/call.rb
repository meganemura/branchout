# frozen_string_literal: true

module FixtureCall
  def self.entry(x)
    if x > 0
      bucket(x)
    else
      :nonpos
    end
  end

  def self.bucket(x)
    if x > 10
      :big
    else
      :small
    end
  end

  def self.unused(x)
    if x == 9
      :nope
    else
      :also
    end
  end
end
