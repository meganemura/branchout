# frozen_string_literal: true

module ShelfLabel
  def label(item) = item.empty? ? "unnamed" : item
end
