# frozen_string_literal: true

module VersionParser
  def self.parse(text)
    if text.empty?
      :blank
    elsif text.include?("-")
      _version, tag = text.split("-", 2)
      if tag.start_with?("rc")
        :rc
      elsif tag.start_with?("beta")
        :beta
      else
        :pre
      end
    elsif release?(text)
      :release
    else
      :other
    end
  end

  def self.release?(text)
    parts = text.split(".")
    return false unless parts.length == 3

    parts.all? { |part| part.match?(/\A[0-9]+\z/) }
  end
end
