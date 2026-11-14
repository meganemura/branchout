# frozen_string_literal: true
# rbs_inline: enabled

module Branchout
  # Ruby source that an input passes in place of a JSON value: a record, an
  # exception, or a block, which JSON cannot write. An inputs file spells it
  # {"ruby": "Factories.loan(3)"}. Each call evaluates it again, so every
  # call gets a new object, and an emitted test writes it as it was given.
  Code = Data.define(
    :source #: String
  )

  # Its methods are in a class body, not in the block of Data.define, so
  # that rbs-inline reads their types and steep checks them.
  class Code
    #: (String) -> Code
    def self.parse(source)
      raise Error, "Ruby #{source.inspect} does not parse" unless Prism.parse(source).errors.empty?

      new(-source)
    end

    # A block as a call takes it, written with braces so it binds to the
    # call in an emitted assertion as it did in explore. +source+ is what
    # an inputs file gives, so any JSON value.
    #: (Object) -> Code
    def self.block(source)
      raise Error, "block #{source.inspect} is not a block such as \"{ |item| item.price > 2 }\"" unless source.is_a?(String)

      body = Prism.parse("m #{source}").value.statements.body
      # "m {" starts a call, so the one statement is the call to m.
      call = body.first
      unless source.start_with?("{") && body.length == 1 && call.is_a?(Prism::CallNode) && call.block
        raise Error, "block #{source.inspect} is not a block such as \"{ |item| item.price > 2 }\""
      end

      new(-source)
    end

    # One expression, as an emitted test passes it to assert_equal or
    # expect: a modifier if or two statements would not parse there.
    # +source+ is what an inputs file gives, so any JSON value.
    #: (Object, String) -> Code
    def self.expression(source, example)
      raise Error, "Ruby #{source.inspect} is not one expression such as #{example.inspect}" unless source.is_a?(String)

      code = parse(source)
      unless Prism.parse(source).value.statements.body.length == 1 && Prism.parse("m(#{source})").errors.empty?
        raise Error, "Ruby #{source.inspect} is not one expression such as #{example.inspect}; " \
                     "read several values as one Array or Hash"
      end

      code
    end

    #: () -> String
    def to_s = source
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
    SetupCall = Struct.new(
      :method_name, #: String
      :arguments #: Input
    )

    # Its method is in a class body, so that rbs-inline and steep read it.
    class SetupCall
      #: () -> Hash[String, plain]
      def to_h
        arguments.to_h.merge("method" => method_name)
      end
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
    # @rbs!
    #   # An argument as normalize leaves it: a Symbol reads as a String, and
    #   # a Hash has String keys.
    #   type value = nil | bool | Integer | Float | String | Code | Array[value] | Hash[String, value]

    attr_reader :args #: Array[value]
    attr_reader :kwargs #: Hash[String, value]
    attr_reader :receiver #: Input | Code | nil
    attr_reader :setup #: Array[SetupCall]
    attr_reader :pin_keys #: Array[String]?
    attr_reader :block #: Code?
    attr_reader :before #: Code?
    attr_reader :note #: String?
    attr_reader :after #: Code?

    # @rbs args: Array[plain]
    # @rbs kwargs: Hash[String | Symbol, plain]?
    # @rbs receiver: Input | Code | nil
    # @rbs setup: Array[SetupCall]
    # @rbs pin_keys: Array[String]?
    # @rbs block: Code?
    # @rbs before: Code?
    # @rbs note: String?
    # @rbs after: Code?
    # @rbs return: void
    def initialize(args:, kwargs: {}, receiver: nil, setup: [], pin_keys: nil, block: nil, before: nil, note: nil, after: nil)
      normalized = normalize(args)
      deep_freeze(normalized)
      unless normalized.is_a?(Array)
        raise Error, "input args must be an array"
      end

      @args = normalized
      raw_kwargs = kwargs || {}
      unless raw_kwargs.is_a?(Hash)
        raise Error, "input kwargs must be an object"
      end

      named = {} #: Hash[String, value]
      raw_kwargs.each { |key, value| named[key.to_s] = normalize(value) }
      deep_freeze(named)
      @kwargs = named
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
    # @rbs args: Array[plain]
    # @rbs kwargs: Hash[String | Symbol, plain]?
    # @rbs receiver: Input | Code | nil
    # @rbs setup: Array[SetupCall]
    # @rbs pin_keys: Array[String]?
    # @rbs block: Code?
    # @rbs before: Code?
    # @rbs note: String?
    # @rbs after: Code?
    # @rbs return: Input
    def with(args: self.args, kwargs: self.kwargs, receiver: self.receiver, setup: self.setup, pin_keys: self.pin_keys, block: self.block,
             before: self.before, note: self.note, after: self.after)
      Input.new(args: args, kwargs: kwargs, receiver: receiver, setup: setup, pin_keys: pin_keys, block: block, before: before, note: note, after: after)
    end

    #: () -> Hash[String, plain]
    def to_h
      hash = {"args" => args, "kwargs" => kwargs} #: Hash[String, plain]
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

    #: () -> Hash[String, plain]
    def short_h
      hash = to_h
      hash.delete("kwargs") if kwargs.empty?
      # to_h writes "new" only for an Input receiver.
      built = receiver
      hash["new"] = built.short_h if built.is_a?(Input)
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
        setup.sum { |call| call.arguments.weight + 1 } +
        (block ? block.source.length : 0) +
        (before ? before.source.length : 0) +
        (after ? after.source.length : 0)
    end

    #: (value | Input) -> (Integer | Float)
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

    #: (String?) -> (Integer | Float | String | Array[bot] | Hash[bot, bot] | bool)
    def self.zero(type)
      case type
      when "int" then 0
      when "float" then 0.0
      when "string" then ""
      when "array" then [] #: Array[bot]
      when "hash" then {} #: Hash[bot, bot]
      when "bool" then false
      else
        raise Error, "unknown type #{type}"
      end
    end

    # A value of another class is refused, whatever the signature says.
    #: (plain) -> value
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
        source = value.values.first
        return Code.parse(source) if code?(value) && source.is_a?(String)

        out = {} #: Hash[String, value]
        value.each { |key, item| out[key.to_s] = normalize(item) }
        out
      else
        raise Error, "unsupported input value #{value.class}"
      end
    end

    # {"ruby": "..."} is Ruby source. A Hash argument with one key "ruby"
    # is written as Ruby too: {"ruby": "{\"ruby\" => \"3.4\"}"}.
    #: (Hash[String | Symbol, plain]) -> bool
    def code?(value)
      value.length == 1 && value.keys.first.to_s == "ruby" && value.values.first.is_a?(String)
    end

    # Freezes +value+ and every Array and Hash in it, in place.
    #: (value) -> void
    def deep_freeze(value)
      case value
      when Array
        value.each { |item| deep_freeze(item) }
        value.freeze
      when Hash
        value.each { |key, item| deep_freeze(item) }
        value.freeze
      end
    end
  end
end
