# frozen_string_literal: true

class FixtureDelegate
  def self.apply(x) = new.check(x)

  def self.forward(x) = Integer(x).to_s

  def check(x)
    x.positive? ? :yes : :no
  end
end

class FixtureDocument
  def self.apply(doc) = self.new(doc).kind

  def initialize(doc)
    @doc = doc.empty? ? "(blank)" : doc
  end

  def kind
    @doc.start_with?("#") ? :heading : :text
  end
end

class FixtureParser
  attr_reader :kind

  def self.parse(text) = new(text).tap(&:read)

  def initialize(text)
    @text = text
  end

  def read
    @kind = @text.include?("=") ? :pair : :word
  end
end
