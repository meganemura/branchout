# frozen_string_literal: true

module Branchout
  # Ruby source that an input passes in place of a JSON value: a record, an
  # exception, or a block, which JSON cannot write. An inputs file spells it
  # {"ruby": "Factories.loan(3)"}. Each call evaluates it again, so every
  # call gets a new object, and an emitted test writes it as it was given.
  Code = Data.define(:source) do
    def self.parse(source)
      raise Error, "Ruby #{source.inspect} does not parse" unless Prism.parse(source).errors.empty?

      new(-source)
    end

    # A block as a call takes it, written with braces so it binds to the
    # call in an emitted assertion as it did in explore.
    def self.block(source)
      body = Prism.parse("m #{source}").value.statements.body
      unless source.start_with?("{") && body.length == 1 && body.first.respond_to?(:block) && body.first.block
        raise Error, "block #{source.inspect} is not a block such as \"{ |item| item.price > 2 }\""
      end

      new(-source)
    end

    def to_s = source
  end

  class Input
    # One call made on the receiver after new and before the entry.
    # +arguments+ is an Input with no receiver and no setup of its own.
    SetupCall = Struct.new(:method_name, :arguments) do
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
    attr_reader :args, :kwargs, :receiver, :setup, :pin_keys, :block

    def initialize(args:, kwargs: {}, receiver: nil, setup: [], pin_keys: nil, block: nil)
      @args = deep_freeze(normalize(args))
      unless @args.is_a?(Array)
        raise Error, "input args must be an array"
      end

      raw_kwargs = kwargs || {}
      unless raw_kwargs.is_a?(Hash)
        raise Error, "input kwargs must be an object"
      end

      @kwargs = deep_freeze(raw_kwargs.each_with_object({}) { |(key, value), out|
        out[key.to_s] = normalize(value)
      })
      @receiver = receiver
      @setup = setup.map { |call| SetupCall.new(-call.method_name.to_s, call.arguments).freeze }.freeze
      @pin_keys = pin_keys&.map { |key| -key }.freeze
      @block = block
      freeze
    end

    def to_h
      hash = {"args" => args, "kwargs" => kwargs}
      if receiver.is_a?(Code)
        hash["receiver"] = receiver
      elsif receiver
        hash["new"] = receiver.to_h
      end
      hash["setup"] = setup.map(&:to_h) unless setup.empty?
      hash["block"] = block.source if block
      hash
    end

    def canonical
      Canon.json(to_h)
    end

    # Short form used in the text report. An input with only args prints as
    # the args array so an agent can paste it back into inputs.json.
    def text
      kwargs.empty? && receiver.nil? && setup.empty? && block.nil? ? Canon.json(args) : Canon.json(to_h)
    end

    # Smaller is a simpler witness: absolute numeric size, then string
    # length, and each setup call counts one.
    def weight
      args.sum { |value| self.class.weight_of(value) } +
        kwargs.values.sum { |value| self.class.weight_of(value) } +
        self.class.weight_of(receiver) +
        setup.sum { |call| 1 + call.arguments.weight } +
        (block ? block.source.length : 0)
    end

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

    def self.zero(type)
      case type
      when "int" then 0
      when "float" then 0.0
      when "string" then ""
      when "array" then []
      when "hash" then {}
      when "bool" then false
      else
        raise Error, "unknown type #{type}"
      end
    end

    def normalize(value)
      case value
      when nil, true, false, Integer
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

        value.each_with_object({}) do |(key, item), out|
          out[key.to_s] = normalize(item)
        end
      else
        raise Error, "unsupported input value #{value.class}"
      end
    end

    # {"ruby": "..."} is Ruby source. A Hash argument with one key "ruby"
    # is written as Ruby too: {"ruby": "{\"ruby\" => \"3.4\"}"}.
    def code?(value)
      value.length == 1 && value.keys.first.to_s == "ruby" && value.values.first.is_a?(String)
    end

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
