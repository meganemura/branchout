# frozen_string_literal: true
# rbs_inline: enabled

module Branchout
  class Sampler
    ALPHABET = "abc01.-" #: String
    INT_MIN = -3 #: Integer
    INT_MAX = 12 #: Integer

    # @rbs @target: Target
    # @rbs @rng: Rng
    # @rbs @count: Integer

    #: (Target, seed: Integer, count: Integer) -> void
    def initialize(target, seed:, count:)
      @target = target
      @rng = Rng.new(seed)
      @count = count
      raise Error, "random count must be >= 0" if count.negative?
    end

    #: () -> Array[Input]
    def inputs
      Array.new(@count) { build }
    end

    # The entry's values are drawn before the constructor's, so the stream
    # for a class method is the same as before constructors were sampled.
    #: () -> Input
    def build
      entry = draw(@target.parameters)
      return entry if @target.constructor.empty?

      Input.new(args: entry.args, kwargs: entry.kwargs, receiver: draw(@target.constructor))
    end

    #: (Array[Target::Parameter]) -> Input
    def draw(parameters)
      args = parameters.select { |param| param.kind == :req || param.kind == :opt }.map { |param| sample(param.inferred_type) }
      kwargs = {} #: Hash[String, untyped]
      parameters.each do |param|
        next unless param.kind == :keyreq

        kwargs[param.name.to_s] = sample(param.inferred_type)
      end
      Input.new(args: args, kwargs: kwargs)
    end

    #: (String?) -> (Integer | Float | String | Array[Integer] | Hash[String, Integer] | bool)
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
        out = {} #: Hash[String, Integer]
        length.times do |index|
          out[keys[index]] = @rng.rand_inclusive(INT_MIN, INT_MAX)
        end
        out
      when "bool"
        @rng.rand_inclusive(0, 1) == 1
      else
        Input.zero(type)
      end
    end
  end
end
