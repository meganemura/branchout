# frozen_string_literal: true

# Holds a name while its block runs, so what a call leaves in held is half
# of what take does: a block that raises frees the name, and :keep holds it.
class FixtureLatch
  def initialize = @held = []

  def held = @held.dup

  def take(name)
    raise ArgumentError, "#{name} is held" if @held.include?(name)

    @held << name
    value = yield
    @held.delete(name) unless value == :keep
    value
  rescue RuntimeError
    @held.delete(name)
    raise
  end
end
