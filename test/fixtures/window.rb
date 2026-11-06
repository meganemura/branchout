# frozen_string_literal: true

require "date"

class FixtureWindow
  def self.open_on?(h, on:)
    start_date = parse_date(h[:start])
    return false if start_date.nil? || start_date > on

    end_date = parse_date(h[:end])
    end_date.nil? || on < end_date
  end

  def self.parse_date(text) = text && Date.parse(text)
end
