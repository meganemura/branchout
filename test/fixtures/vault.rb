# frozen_string_literal: true

class FixtureVault
  private_class_method :new

  def initialize(code)
    @code = code
  end

  private_class_method def self.seal(word)
    word.empty? ? :blank : :sealed
  end

  def unlock(guess) = check(guess)

  protected

  def peek(guess)
    guess == @code ? :match : :miss
  end

  private

  def check(guess)
    guess == @code ? :open : :shut
  end
end
