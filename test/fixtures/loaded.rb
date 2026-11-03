# frozen_string_literal: true

module FixtureLoaded
  def self.over?(n)
    if n > LIMIT
      :over
    else
      :under
    end
  end
end
