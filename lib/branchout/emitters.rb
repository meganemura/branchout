# frozen_string_literal: true

require_relative "emitters/support"
require_relative "emitters/minitest"
require_relative "emitters/rspec"

module Branchout
  module Emitters
    FORMATS = %w[minitest rspec].freeze

    module_function

    def resolve(explicit, path)
      if explicit
        unless FORMATS.include?(explicit)
          raise Error, "format must be minitest or rspec"
        end

        return explicit
      end
      return "rspec" if path.to_s.end_with?("_spec.rb")

      "minitest"
    end

    def write(format, result, target, destination, require_by_name: false, pin_keys: [])
      Support.write_file(destination, render(format, result, target, destination, require_by_name: require_by_name, pin_keys: pin_keys))
    end

    # +pin_keys+ names the keys a returned Hash pins; empty pins it whole.
    def render(format, result, target, destination, require_by_name: false, pin_keys: [])
      emitter_for(format).render(result, target, destination, require_by_name: require_by_name, pin_keys: pin_keys)
    end

    def emitter_for(format)
      case resolve(format, nil)
      when "minitest" then Minitest
      when "rspec" then RSpec
      end
    end
  end
end
