# frozen_string_literal: true
# rbs_inline: enabled

module Branchout
  # Ruby source that an input passes in place of a JSON value: a record, an
  # exception, or a block, which JSON cannot write. An inputs file spells it
  # {"ruby": "Factories.loan(3)"}. Each call evaluates it again, so every
  # call gets a new object, and an emitted test writes it as it was given.
  #
  # Neither rbs-inline nor steep reads the methods of a Data.define block, so
  # sig/branchout/code.rbs declares them, and steep does not check them.
  Code = Data.define(
    :source #: String
  ) do
    # steep:ignore:start

    def self.parse(source)
      raise Error, "Ruby #{source.inspect} does not parse" unless Prism.parse(source).errors.empty?

      new(-source)
    end

    # A block as a call takes it, written with braces so it binds to the
    # call in an emitted assertion as it did in explore.
    def self.block(source)
      raise Error, "block #{source.inspect} is not a block such as \"{ |item| item.price > 2 }\"" unless source.is_a?(String)

      body = Prism.parse("m #{source}").value.statements.body
      unless source.start_with?("{") && body.length == 1 && body.first.respond_to?(:block) && body.first.block
        raise Error, "block #{source.inspect} is not a block such as \"{ |item| item.price > 2 }\""
      end

      new(-source)
    end

    # One expression, as an emitted test passes it to assert_equal or
    # expect: a modifier if or two statements would not parse there.
    def self.expression(source, example)
      raise Error, "Ruby #{source.inspect} is not one expression such as #{example.inspect}" unless source.is_a?(String)

      code = parse(source)
      unless Prism.parse(source).value.statements.body.length == 1 && Prism.parse("m(#{source})").errors.empty?
        raise Error, "Ruby #{source.inspect} is not one expression such as #{example.inspect}; " \
                     "read several values as one Array or Hash"
      end

      code
    end

    def to_s = source

    # steep:ignore:end
  end

  # A String input that names a path under the emitted test's project. The
  # test writes it from its own directory (+from_test+), so it passes in a
  # copy of the project on another machine. Its text is the path from the
  # project root, which the test's names and descriptions say.
  class ProjectPath < String
    attr_reader :from_test #: String

    #: (String, String) -> void
    def initialize(from_root, from_test)
      super(from_root)
      @from_test = -from_test
      freeze
    end
  end

  # A returned String or an error message that holds paths under the
  # emitted test's project. The test writes the project root from its own
  # directory (+root_from_test+) between the +pieces+, so it passes in a
  # copy of the project on another machine. Its text says each path from
  # the project root, as a ProjectPath does.
  class ProjectText < String
    attr_reader :pieces #: Array[String]
    attr_reader :root_from_test #: String

    #: (Array[String], String) -> void
    def initialize(pieces, root_from_test)
      super(pieces.join)
      @pieces = pieces.map { |piece| -piece }.freeze
      @root_from_test = -root_from_test
      freeze
    end
  end

  class Input
    # One call made on the receiver after new and before the entry.
    # +arguments+ is an Input with no receiver and no setup of its own.
    # sig/branchout/input.rbs declares the method of the block, which neither
    # rbs-inline nor steep reads.
    SetupCall = Struct.new(
      :method_name, #: String
      :arguments #: Input
    ) do
      # steep:ignore:start

      def to_h
        arguments.to_h.merge("method" => method_name)
      end

      # steep:ignore:end
    end

    # +receiver+ is the Input whose arguments go to new for a Const#method
    # entry, the Code that builds the receiver itself (a factory call that
    # returns a saved record), or nil to call new with none. +setup+ lists
    # the SetupCalls that build the receiver's state. +pin_keys+, when not nil, replaces
    # --pin-keys for this input's test. It is not part of the call, so it is
    # not in to_h. +block+ is the Code of the block the entry gets, or nil.
    # +before+ is the Code that makes what the call reads, such as the rows
    # a class method looks up, run first in the input's savepoint, or nil.
    # +note+ is the reason the inputs file gives for the input, which names
    # it in the report and in an emitted test. Like +pin_keys+, it is not
    # part of the call, so it is not in to_h.
    # +after+ is the Code of one expression that reads what the call left,
    # such as the receiver's state, once the call returned or raised, or
    # nil. Its value is pinned beside the call's, so it is in to_h: two
    # inputs that read different things are two tests.
    attr_reader :args #: Array[untyped]
    attr_reader :kwargs #: Hash[String, untyped]
    attr_reader :receiver #: Input | Code | nil
    attr_reader :setup #: Array[SetupCall]
    attr_reader :pin_keys #: Array[String]?
    attr_reader :block #: Code?
    attr_reader :before #: Code?
    attr_reader :note #: String?
    attr_reader :after #: Code?

    # @rbs args: Array[untyped]
    # @rbs kwargs: Hash[String | Symbol, untyped]?
    # @rbs receiver: Input | Code | nil
    # @rbs setup: Array[SetupCall]
    # @rbs pin_keys: Array[String]?
    # @rbs block: Code?
    # @rbs before: Code?
    # @rbs note: String?
    # @rbs after: Code?
    # @rbs return: void
    def initialize(args:, kwargs: {}, receiver: nil, setup: [], pin_keys: nil, block: nil, before: nil, note: nil, after: nil)
      @args = deep_freeze(normalize(args))
      unless @args.is_a?(Array)
        raise Error, "input args must be an array"
      end

      raw_kwargs = kwargs || {}
      unless raw_kwargs.is_a?(Hash)
        raise Error, "input kwargs must be an object"
      end

      @kwargs = deep_freeze(raw_kwargs.each_with_object({}) { |(key, value), out| # steep:ignore UnannotatedEmptyCollection
        out[key.to_s] = normalize(value)
      })
      @receiver = receiver
      @setup = setup.map { |call| SetupCall.new(-call.method_name.to_s, call.arguments).freeze }.freeze
      @pin_keys = pin_keys&.map { |key| -key }.freeze
      @block = block
      @before = before
      @note = note && -note
      @after = after
      freeze
    end

    # This input with +changes+ in place of its own parts.
    #: (**untyped) -> Input
    def with(**changes)
      parts = {args: args, kwargs: kwargs, receiver: receiver, setup: setup, pin_keys: pin_keys, block: block, before: before, note: note, after: after}
      Input.new(**parts, **changes) # steep:ignore InsufficientKeywordArguments
    end

    #: () -> Hash[String, untyped]
    def to_h
      hash = {"args" => args, "kwargs" => kwargs} #: Hash[String, untyped]
      if receiver.is_a?(Code)
        hash["receiver"] = receiver
      elsif receiver
        hash["new"] = receiver.to_h
      end
      hash["setup"] = setup.map(&:to_h) unless setup.empty?
      hash["block"] = block.source if block
      hash["before"] = before if before
      hash["after"] = after if after
      hash
    end

    #: () -> String
    def canonical
      Canon.json(to_h)
    end

    # Short form used in the text report. An input with only args prints as
    # the args array so an agent can paste it back into inputs.json. The
    # entry form leaves out empty kwargs, which an inputs file may omit.
    #: () -> String
    def text
      return Canon.json(args) if kwargs.empty? && receiver.nil? && setup.empty? && block.nil? && before.nil? && after.nil?

      Canon.json(short_h)
    end

    #: () -> Hash[String, untyped]
    def short_h
      hash = to_h
      hash.delete("kwargs") if kwargs.empty?
      # to_h writes "new" only for an Input receiver.
      hash["new"] = receiver.short_h if hash.key?("new") # steep:ignore NoMethod
      hash["setup"] = setup.map { |call| call.arguments.short_h.merge("method" => call.method_name) } unless setup.empty?
      hash
    end

    # Smaller is a simpler witness: absolute numeric size, then string
    # length, and each setup call counts one.
    #: () -> (Integer | Float)
    def weight
      args.sum { |value| self.class.weight_of(value) } +
        kwargs.values.sum { |value| self.class.weight_of(value) } +
        self.class.weight_of(receiver) +
        setup.sum { |call| 1 + call.arguments.weight } + # steep:ignore UnresolvedOverloading
        (block ? block.source.length : 0) +
        (before ? before.source.length : 0) +
        (after ? after.source.length : 0)
    end

    #: (untyped) -> (Integer | Float)
    def self.weight_of(value)
      case value
      when Integer then value.abs
      when Float then value.abs
      when String then value.length
      when Code then value.source.length
      when Input then value.weight
      when Array then value.length + value.sum { |item| weight_of(item) }
      when Hash then value.length + value.values.sum { |item| weight_of(item) }
      else 0
      end
    end

    #: (String?) -> (Integer | Float | String | Array[untyped] | Hash[untyped, untyped] | bool)
    def self.zero(type)
      case type
      when "int" then 0
      when "float" then 0.0
      when "string" then ""
      when "array" then []
      when "hash" then {} #: Hash[untyped, untyped]
      when "bool" then false
      else
        raise Error, "unknown type #{type}"
      end
    end

    #: (untyped) -> untyped
    def normalize(value)
      case value
      when nil, true, false, Integer, ProjectPath
        value
      when String, Symbol
        -value.to_s
      when Float
        raise Error, "non-finite float" unless value.finite?

        value.zero? ? 0.0 : value
      when Code
        value
      when Array
        value.map { |item| normalize(item) }
      when Hash
        return Code.parse(value.values.first) if code?(value)

        value.each_with_object({}) do |(key, item), out| # steep:ignore UnannotatedEmptyCollection
          out[key.to_s] = normalize(item)
        end
      else
        raise Error, "unsupported input value #{value.class}"
      end
    end

    # {"ruby": "..."} is Ruby source. A Hash argument with one key "ruby"
    # is written as Ruby too: {"ruby": "{\"ruby\" => \"3.4\"}"}.
    #: (Hash[untyped, untyped]) -> bool
    def code?(value)
      value.length == 1 && value.keys.first.to_s == "ruby" && value.values.first.is_a?(String)
    end

    # It returns +value+ itself; steep does not narrow a type parameter in a
    # case, so the signature cannot say so.
    #: (untyped) -> untyped
    def deep_freeze(value)
      case value
      when Array
        value.each { |item| deep_freeze(item) }
        value.freeze
      when Hash
        value.each { |key, item| deep_freeze(item) }
        value.freeze
      else
        value
      end
    end
  end
end
