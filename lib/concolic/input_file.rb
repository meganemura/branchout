# frozen_string_literal: true

module Concolic
  module InputFile
    module_function

    def load(path)
      raise Error, "inputs file not found: #{path}" unless File.file?(path)

      begin
        data = JSON.parse(File.read(path))
      rescue JSON::ParserError => e
        raise Error, "invalid JSON in #{path}: #{e.message}"
      end

      types = nil
      entries = data
      if data.is_a?(Hash)
        types = data["types"]
        entries = data["inputs"]
        raise Error, "#{path} is missing \"inputs\"" if entries.nil?
      end
      raise Error, "#{path} inputs must be an array" unless entries.is_a?(Array)
      if types && !types.is_a?(Array)
        raise Error, "#{path} types must be an array"
      end
      if types&.any? { |type| !Mutator::TYPES.include?(type) }
        raise Error, "#{path} has an unknown type (#{Mutator::TYPES.join(", ")})"
      end

      inputs = entries.each_with_index.map { |entry, index| parse_entry(entry, "#{path} inputs[#{index}]") }
      [inputs, types]
    end

    def parse_entry(entry, label)
      case entry
      when Array
        Input.new(args: entry)
      when Hash
        unknown = entry.keys - %w[args kwargs]
        raise Error, "#{label} has unknown keys: #{unknown.join(", ")}" unless unknown.empty?
        raise Error, "#{label} is missing args" unless entry.key?("args")

        Input.new(args: entry["args"], kwargs: entry["kwargs"] || {})
      else
        raise Error, "#{label} must be an array or an object"
      end
    end
  end
end
