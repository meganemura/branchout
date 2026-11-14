# frozen_string_literal: true
# rbs_inline: enabled

module Branchout
  # Park-Miller minimal standard generator. Pure Ruby so the stream does not
  # depend on CRuby's Random implementation.
  class Rng
    MOD = 2_147_483_647 #: Integer
    MULTIPLIER = 16_807 #: Integer

    # @rbs @state: Integer

    #: (Integer | String) -> void
    def initialize(seed)
      value = Integer(seed)
      raise Error, "seed must be >= 0" if value.negative?

      @state = value % MOD
      @state = 1 if @state.zero?
    end

    #: () -> Integer
    def next_int
      @state = (MULTIPLIER * @state) % MOD
    end

    #: (Integer, Integer) -> Integer
    def rand_inclusive(min, max)
      min = Integer(min)
      max = Integer(max)
      span = max - min + 1
      raise Error, "empty range #{min}..#{max}" if span <= 0

      min + (next_int % span)
    end
  end
end
