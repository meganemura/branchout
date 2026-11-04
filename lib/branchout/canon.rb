# frozen_string_literal: true

module Branchout
  # Byte-stable JSON. Key order is sorted, floats have a fixed spelling,
  # and non-ASCII is escaped so the bytes do not depend on a JSON mode flag.
  module Canon
    module_function

    def json(obj)
      case obj
      when nil then "null"
      when true then "true"
      when false then "false"
      when Integer then obj.to_s
      when Float then format_float(obj)
      when String then JSON.generate(obj, ascii_only: true)
      when Symbol then JSON.generate(obj.to_s, ascii_only: true)
      when Code then json({"ruby" => obj.source})
      when Array
        "[#{obj.map { |item| json(item) }.join(",")}]"
      when Hash
        pairs = obj.map { |key, value| [key.to_s, value] }.sort_by { |key, _| key }
        "{#{pairs.map { |key, value| "#{json(key)}:#{json(value)}" }.join(",")}}"
      else
        raise Error, "cannot encode #{obj.class} as canonical JSON"
      end
    end

    # Float#to_s is the shortest text that reads back as the same float in
    # Ruby and in JSON. A fixed precision is not: %.16g printed 0.1 + 0.2 as
    # 0.3, and the largest float as a number that parses to Infinity.
    def format_float(value)
      raise Error, "non-finite float" unless value.finite?
      return "0.0" if value.zero?

      value.to_s
    end

    def pretty(obj, indent = 0)
      pad = "  " * indent
      case obj
      when Hash
        return "{}" if obj.empty?

        inner = obj.map do |key, value|
          "#{"  " * (indent + 1)}#{json(key.to_s)}: #{pretty(value, indent + 1)}"
        end
        "{\n#{inner.join(",\n")}\n#{pad}}"
      when Array
        return "[]" if obj.empty?

        inner = obj.map { |value| "#{"  " * (indent + 1)}#{pretty(value, indent + 1)}" }
        "[\n#{inner.join(",\n")}\n#{pad}]"
      else
        json(obj)
      end
    end
  end
end
