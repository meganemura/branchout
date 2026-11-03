# frozen_string_literal: true

module Concolic
  class Sampler
    ALPHABET = "abc01.-"
    INT_MIN = -3
    INT_MAX = 12

    def initialize(target, seed:, count:)
      @target = target
      @rng = Rng.new(seed)
      @count = count
      raise Error, "random count must be >= 0" if count.negative?
    end

    def inputs
      Array.new(@count) { build }
    end

    def build
      args = @target.positional.map { |param| sample(param.inferred_type) }
      kwargs = {}
      @target.keywords.each do |param|
        next unless param.kind == :keyreq

        kwargs[param.name.to_s] = sample(param.inferred_type)
      end
      Input.new(args: args, kwargs: kwargs)
    end

    def sample(type)
      case type
      when "int"
        @rng.rand_inclusive(INT_MIN, INT_MAX)
      when "float"
        base = @rng.rand_inclusive(INT_MIN, INT_MAX)
        half = @rng.rand_inclusive(0, 1)
        value = base + (half * 0.5)
        value.zero? ? 0.0 : value
      when "string"
        length = @rng.rand_inclusive(0, 3)
        length.times.map { ALPHABET[@rng.rand_inclusive(0, ALPHABET.length - 1)] }.join
      when "array"
        length = @rng.rand_inclusive(0, 2)
        Array.new(length) { @rng.rand_inclusive(INT_MIN, INT_MAX) }
      when "hash"
        length = @rng.rand_inclusive(0, 2)
        keys = %w[a b c]
        out = {}
        length.times do |index|
          out[keys[index]] = @rng.rand_inclusive(INT_MIN, INT_MAX)
        end
        out
      else
        Input.zero(type)
      end
    end
  end
end
