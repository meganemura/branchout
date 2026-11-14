# frozen_string_literal: true
# rbs_inline: enabled

module Branchout
  module InputFile
    module_function

    # The inputs, the types, and the file's after.
    #: (String) -> [Array[Input], Array[String]?, Code?]
    def load(path)
      raise Error, "inputs file not found: #{path}" unless File.file?(path)

      begin
        # JSON is UTF-8 whatever the locale says, and under LANG=C a note in
        # another script would not read.
        data = JSON.parse(File.read(path, encoding: "UTF-8"))
      rescue JSON::ParserError => e
        raise Error, "invalid JSON in #{path}: #{e.message}"
      end

      types = nil
      after = nil
      entries = data
      if data.is_a?(Hash)
        types = data["types"]
        entries = data["inputs"]
        raise Error, "#{path} is missing \"inputs\"" if entries.nil?

        after = parse_after(data["after"], path) if data.key?("after")
      end
      raise Error, "#{path} inputs must be an array" unless entries.is_a?(Array)
      if types && !types.is_a?(Array)
        raise Error, "#{path} types must be an array"
      end
      if types&.any? { |type| !Mutator::TYPES.include?(type) }
        raise Error, "#{path} has an unknown type (#{Mutator::TYPES.join(", ")})"
      end

      inputs = entries.each_with_index.map { |entry, index| parse_entry(entry, "#{path} inputs[#{index}]") }
      # The file's after reads what every call left, unless an input reads
      # something of its own.
      inputs = inputs.map { |input| input.after ? input : input.with(after: after) } if after
      [inputs, types, after]
    end

    AFTER_EXAMPLE = "{\"ruby\": \"cart.items\"}" #: String

    # The Code of an after: one expression, which an emitted test pins as
    # it pins a returned value.
    #: (untyped, String) -> Code
    def parse_after(value, label)
      raise Error, "#{label} after must be Ruby such as #{AFTER_EXAMPLE}" unless value.is_a?(Hash) && code?(value)

      Code.expression(value["ruby"], "cart.items")
    rescue Error => e
      raise if e.message.start_with?(label)

      raise Error, "#{label} after #{e.message.sub(/\ARuby /, "")}"
    end

    # Keys that say how the entry is called, so args may be left out for none.
    CALL_KEYS = %w[new receiver setup kwargs block before after].freeze #: Array[String]

    METHOD_NAME = /\A(?:[A-Za-z_][A-Za-z0-9_]*[?!=]?|<<|>>|\[\]=?|[-+*\/%&|^<>]|\*\*|<=>|==|!=|<=|>=|=~)\z/ #: Regexp

    #: (untyped, String, ?Array[String]) -> Input
    def parse_entry(entry, label, keys = %w[args kwargs new receiver setup note pin_keys block before after])
      case entry
      when Array
        Input.new(args: entry)
      when Hash
        unknown = entry.keys - keys
        raise Error, "#{label} has unknown keys: #{unknown.join(", ")}" unless unknown.empty?
        unless entry.key?("args") || label.end_with?(" new") || CALL_KEYS.any? { |key| entry.key?(key) }
          raise Error, "#{label} is missing args; write \"args\": [] for a call with no arguments"
        end

        receiver = parse_entry(entry["new"], "#{label} new", %w[args kwargs new]) if entry.key?("new")
        raise Error, "#{label} new cannot have its own new" if receiver&.receiver
        if entry.key?("receiver")
          raise Error, "#{label} gives both new and receiver; receiver builds the object itself" if receiver

          built = entry["receiver"]
          raise Error, "#{label} receiver must be Ruby such as {\"ruby\": \"create(:loan)\"}" unless built.is_a?(Hash) && code?(built)

          receiver = Code.parse(built["ruby"])
        end

        setup = parse_setup(entry.fetch("setup", []), "#{label} setup")
        pin_keys = entry["pin_keys"]
        unless pin_keys.nil? || (pin_keys.is_a?(Array) && pin_keys.all? { |key| key.is_a?(String) && !key.empty? })
          raise Error, "#{label} pin_keys must be an array of key names"
        end

        block = Code.block(entry["block"]) if entry.key?("block")
        if entry.key?("before")
          raise Error, "#{label} before must be Ruby such as {\"ruby\": \"create(:part)\"}" unless entry["before"].is_a?(Hash) && code?(entry["before"])

          before = Code.parse(entry["before"]["ruby"])
        end
        # A note that is not a String, which an earlier branchout ignored, is
        # still ignored.
        note = entry["note"] if entry["note"].is_a?(String)
        after = parse_after(entry["after"], label) if entry.key?("after")
        Input.new(args: entry.fetch("args", []), kwargs: entry["kwargs"] || {}, receiver: receiver, setup: setup, pin_keys: pin_keys, block: block,
                  before: before, note: (note unless note&.strip&.empty?), after: after)
      else
        raise Error, "#{label} is #{JSON.generate(entry)}, not a call; write each call as an array of its arguments, such as #{JSON.generate([entry])}"
      end
    rescue Error => e
      raise if e.message.start_with?(label)

      raise Error, "#{label} #{e.message}"
    end

    # A String argument wrapped in its own quotes, as "\"0306406150\"", is
    # most often Ruby or JSON source written where a JSON value goes, and
    # the method then gets the quotes too.
    #: (Array[Input]) -> Array[String]
    def quoted_strings(inputs)
      inputs.each_with_index.flat_map do |input, index|
        named = input.args.each_with_index.map { |value, at| ["args[#{at}]", value] } +
                input.kwargs.map { |key, value| ["kwargs.#{key}", value] }
        named.filter_map do |place, value|
          next unless value.is_a?(String) && value.length >= 2 && value.match?(/\A(["']).*\z/m)

          unquoted = value[1...-1] #: String
          "inputs[#{index}] #{place} is the String #{value.inspect}, quotes included. " \
            "An inputs file is JSON, so write #{unquoted.inspect} for the #{unquoted.empty? ? "empty String" : "String #{unquoted}"}, " \
            "or {\"ruby\": \"...\"} for Ruby source. Keep the quotes only if the method should get them."
        end
      end
    end

    #: (Hash[untyped, untyped]) -> bool
    def code?(value)
      value.keys == ["ruby"] && value["ruby"].is_a?(String)
    end

    #: (untyped, String) -> Array[Input::SetupCall]
    def parse_setup(steps, label)
      raise Error, "#{label} must be an array" unless steps.is_a?(Array)

      steps.each_with_index.map do |step, index|
        step_label = "#{label}[#{index}]"
        raise Error, "#{step_label} must be an object" unless step.is_a?(Hash)

        unknown = step.keys - %w[method args kwargs block]
        raise Error, "#{step_label} has unknown keys: #{unknown.join(", ")}" unless unknown.empty?
        raise Error, "#{step_label} is missing method" unless step.key?("method")

        name = step["method"]
        raise Error, "#{step_label} method #{name.inspect} is not a method name" unless name.is_a?(String) && METHOD_NAME.match?(name)

        begin
          block = Code.block(step["block"]) if step.key?("block")
        rescue Error => e
          raise Error, "#{step_label} #{e.message}"
        end
        Input::SetupCall.new(name, Input.new(args: step.fetch("args", []), kwargs: step["kwargs"] || {}, block: block))
      end
    end
  end
end
