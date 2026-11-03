# frozen_string_literal: true

module FixtureMagic
  def self.classify(x)
    if x == 114514
      :magic
    else
      :plain
    end
  end
end
