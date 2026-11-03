# frozen_string_literal: true

module Branchout
  class Input
    # One call made on the receiver after new and before the entry.
    # +arguments+ is an Input with no receiver and no setup of its own.
    SetupCall = Struct.new(:method_name, :arguments) do
      def to_h
        arguments.to_h.merge("method" => method_name)
      end
    end

    # +receiver+ is the Input whose arguments go to new for a Const#method
    # entry, or nil to call new with none. +setup+ lists the SetupCalls
    # that build the receiver's state.
    attr_reader :args, :kwargs, :receiver, :setup

    def initialize(args:, kwargs: {}, receiver: nil, setup: [])
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
      freeze
    end

    def to_h
      hash = {"args" => args, "kwargs" => kwargs}
      hash["new"] = receiver.to_h if receiver
      hash["setup"] = setup.map(&:to_h) unless setup.empty?
      hash
    end

    def canonical
      Canon.json(to_h)
    end

    # Short form used in the text report. An input with only args prints as
    # the args array so an agent can paste it back into inputs.json.
    def text
      kwargs.empty? && receiver.nil? && setup.empty? ? Canon.json(args) : Canon.json(to_h)
    end

    # Smaller is a simpler witness: absolute numeric size, then string
    # length, and each setup call counts one.
    def weight
      args.sum { |value| self.class.weight_of(value) } +
        kwargs.values.sum { |value| self.class.weight_of(value) } +
        (receiver ? receiver.weight : 0) +
        setup.sum { |call| 1 + call.arguments.weight }
    end

    def self.weight_of(value)
      case value
      when Integer then value.abs
      when Float then value.abs
      when String then value.length
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
      when Array
        value.map { |item| normalize(item) }
      when Hash
        value.each_with_object({}) do |(key, item), out|
          out[key.to_s] = normalize(item)
        end
      else
        raise Error, "unsupported input value #{value.class}"
      end
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
