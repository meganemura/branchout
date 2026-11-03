# frozen_string_literal: true

module FixtureShape
  Point = Struct.new(:x)

  def self.build(n)
    if n.positive?
      Point.new(n)
    else
      {"n" => n}
    end
  end
end
