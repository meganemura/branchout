# frozen_string_literal: true

# An Enumerable class whose entry reaches its own each through select.
class Picks
  include Enumerable

  Item = Data.define(:start, :ok, :name) do
    def ok? = ok
  end

  def initialize(items) = @items = items
  def each(&) = kept.each(&)
  def names = select(&:ok?).map(&:name)

  private

  def kept = @items.select { |item| keep?(item) }

  def keep?(item)
    return false if item.start.nil?

    item.ok?
  end
end
