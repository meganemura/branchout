# frozen_string_literal: true

module FixtureLabel
  def self.shout(text)
    text.upcase
  end

  def self.stamp(_text)
    "done" << "!"
  end
end
