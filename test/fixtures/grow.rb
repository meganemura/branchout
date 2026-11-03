# frozen_string_literal: true

module FixtureGrow
  def self.add(list, text)
    list << text
    text << "!"
    if list.length > 1
      :many
    else
      :one
    end
  end
end
