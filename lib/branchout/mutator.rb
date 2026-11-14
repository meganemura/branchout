# frozen_string_literal: true
# rbs_inline: enabled

module Branchout
  # Literal mutation in the style of a cheap comparison-guided fuzzer.
  # Every source literal is tried in each argument slot. A capped cartesian
  # product of the first two numeric slots comes after that, so a magic
  # constant is not dropped just because it sorts late.
  class Mutator
    TYPES = %w[int float string array hash bool].freeze #: Array[String]

    # @rbs @target: Target
    # @rbs @cap: Integer

    #: (Target, cap: Integer) -> void
    def initialize(target, cap:)
      @target = target
      @cap = cap
      raise Error, "mutate-cap must be >= 0" if cap.negative?
    end

    # A slot is one value an input passes: a positional or required keyword
    # parameter of the entry, or of initialize when the entry is an instance
    # method. Optional keywords keep their defaults.
    Slot = Struct.new(
      :owner, #: :entry | :new
      :param #: Target::Parameter
    )

    #: () -> Array[Input]
    def inputs
      return [] if @cap.zero?

      slots = slots_of(:entry, @target.parameters) + slots_of(:new, @target.constructor)
      base = slots.to_h { |slot| [slot, base_value(slot.param)] }
      pools = slots.to_h { |slot| [slot, pool_for(slot.param)] }

      tier_one = [build(base)]
      slots.each do |slot|
        pools[slot].each { |value| tier_one << build(base.merge(slot => value)) }
      end

      tier_two = [] #: Array[Input]
      # A second slot means a first one.
      first, second = slots.select { |slot| slot.owner == :entry && slot.param.kind != :keyreq } #: [Slot, Slot?]
      if second && numeric?(first.param) && numeric?(second.param)
        pools[first].each do |left|
          pools[second].each { |right| tier_two << build(base.merge(first => left, second => right)) }
        end
      end

      deduped = [] #: Array[Input]
      seen = {} #: Hash[String, bool]
      (sort_inputs(tier_one) + sort_inputs(tier_two)).each do |input|
        key = input.canonical
        next if seen[key]

        seen[key] = true
        deduped << input
        break if deduped.length >= @cap
      end
      deduped
    end

    # Every input passes each required keyword, or the call stops at
    # ArgumentError before the method body runs.
    #: (:entry | :new, Array[Target::Parameter]) -> Array[Slot]
    def slots_of(owner, parameters)
      parameters.select { |param| %i[req opt keyreq].include?(param.kind) }.map { |param| Slot.new(owner, param) }
    end

    #: (Hash[Slot, untyped]) -> Input
    def build(values)
      entry = values.select { |slot, _| slot.owner == :entry }
      made = values.reject { |slot, _| slot.owner == :entry }
      receiver = arguments(made) unless @target.constructor.empty?
      arguments(entry, receiver)
    end

    #: (Hash[Slot, untyped], ?Input?) -> Input
    def arguments(values, receiver = nil)
      args = values.reject { |slot, _| slot.param.kind == :keyreq }.values
      kwargs = values.select { |slot, _| slot.param.kind == :keyreq }.to_h { |slot, value| [slot.param.name.to_s, value] }
      Input.new(args: args, kwargs: kwargs, receiver: receiver)
    end

    #: (Target::Parameter) -> Array[untyped]
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
      when "bool"
        [false, true]
      else
        [Input.zero(param.inferred_type || "int")]
      end
    end

    #: (Target::Parameter) -> untyped
    def base_value(param)
      return param.default unless param.default.nil?

      Input.zero(param.inferred_type)
    end

    #: (Target::Parameter) -> bool
    def numeric?(param)
      param.inferred_type == "int" || param.inferred_type == "float"
    end

    #: (Array[Input]) -> Array[Input]
    def sort_inputs(list)
      list.sort_by(&:canonical)
    end
  end
end
