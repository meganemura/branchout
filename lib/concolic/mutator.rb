# frozen_string_literal: true

module Concolic
  # Literal mutation in the style of a cheap comparison-guided fuzzer.
  # Every source literal is tried in each argument slot. A capped cartesian
  # product of the first two numeric slots comes after that, so a magic
  # constant is not dropped just because it sorts late.
  class Mutator
    TYPES = %w[int float string array hash].freeze

    def initialize(target, cap:)
      @target = target
      @cap = cap
      raise Error, "mutate-cap must be >= 0" if cap.negative?
    end

    def inputs
      return [] if @cap.zero?

      positions = @target.positional
      pools = positions.map { |param| pool_for(param) }
      base_args = positions.map { |param| base_value(param) }
      base_kwargs = {}
      keyword_pools = @target.keywords.select { |param| param.kind == :keyreq }.map { |param|
        [param, pool_for(param)]
      }

      tier_one = []
      tier_one << Input.new(args: base_args, kwargs: base_kwargs)
      pools.each_with_index do |pool, index|
        pool.each do |value|
          args = base_args.dup
          args[index] = value
          tier_one << Input.new(args: args, kwargs: base_kwargs)
        end
      end
      keyword_pools.each do |param, pool|
        pool.each do |value|
          kwargs = base_kwargs.merge(param.name.to_s => value)
          tier_one << Input.new(args: base_args, kwargs: kwargs)
        end
      end

      tier_two = []
      if positions.length >= 2 && numeric?(positions[0]) && numeric?(positions[1])
        pools[0].each do |left|
          pools[1].each do |right|
            args = base_args.dup
            args[0] = left
            args[1] = right
            tier_two << Input.new(args: args, kwargs: base_kwargs)
          end
        end
      end

      deduped = []
      seen = {}
      (sort_inputs(tier_one) + sort_inputs(tier_two)).each do |input|
        key = input.canonical
        next if seen[key]

        seen[key] = true
        deduped << input
        break if deduped.length >= @cap
      end
      deduped
    end

    def pool_for(param)
      literals = @target.literals
      case param.inferred_type
      when "int"
        values = [0, 1, -1]
        values.concat(literals.ints)
        values.concat(literals.ints.flat_map { |number| [number - 1, number + 1] })
        values << param.default if param.default.is_a?(Integer)
        values.grep(Integer).uniq.sort
      when "float"
        values = [0.0, 1.0, -1.0]
        values.concat(literals.floats)
        values.concat(literals.ints.map(&:to_f))
        values.concat(values.flat_map { |number| [number - 1.0, number + 1.0] })
        values << param.default if param.default.is_a?(Float)
        values.grep(Float).select(&:finite?).map { |number| number.zero? ? 0.0 : number }.uniq.sort
      when "string"
        values = ["", "a"]
        values.concat(literals.strings)
        values << param.default if param.default.is_a?(String)
        literals.strings.each do |text|
          values << text[0..-2].to_s
          values << "#{text}1"
        end
        values.uniq.sort
      when "array"
        [[], [0], [1], [0, 1]]
      when "hash"
        [{}, {"a" => 0}, {"a" => 1}]
      else
        [Input.zero(param.inferred_type || "int")]
      end
    end

    def base_value(param)
      return param.default unless param.default.nil?

      Input.zero(param.inferred_type)
    end

    def numeric?(param)
      param.inferred_type == "int" || param.inferred_type == "float"
    end

    def sort_inputs(list)
      list.sort_by(&:canonical)
    end
  end
end
