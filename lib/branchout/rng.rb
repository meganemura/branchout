# frozen_string_literal: true

module Branchout
  # Park-Miller minimal standard generator. Pure Ruby so the stream does not
  # depend on CRuby's Random implementation.
  class Rng
    MOD = 2_147_483_647
    MULTIPLIER = 16_807

    def initialize(seed)
      value = Integer(seed)
      raise Error, "seed must be >= 0" if value.negative?

      @state = value % MOD
      @state = 1 if @state.zero?
    end

    def next_int
      @state = (MULTIPLIER * @state) % MOD
    end

    def rand_inclusive(min, max)
      min = Integer(min)
      max = Integer(max)
      span = max - min + 1
      raise Error, "empty range #{min}..#{max}" if span <= 0

      min + (next_int % span)
    end
  end
end
