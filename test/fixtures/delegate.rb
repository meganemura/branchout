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
