# frozen_string_literal: true

require "date"

class FixtureCalendar
  Slot = Data.define(:name, :on, :note)
  Pair = Struct.new(:name, :on)
  Mark = Struct.new(:name, :at)

  def initialize(start) = @start = start

  def plan(days)
    return { kind: "none", start_at: nil } if days.zero?

    { kind: "span", start_at: @start + days, slots: [Slot.new(name: "a", on: @start + days, note: nil), Pair.new("b", @start)] }
  end

  def marks(days) = days.zero? ? [] : [Mark.new("m", Object.new)]
end
