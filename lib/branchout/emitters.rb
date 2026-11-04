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

    # Returns a warning for each path of this machine that the test passes
    # as it is (Support.machine_paths), for the caller to print.
    def write(format, result, target, destination, require_by_name: false, pin_keys: [])
      Support.write_file(destination, render(format, result, target, destination, require_by_name: require_by_name, pin_keys: pin_keys))
      paths = result.pins.flat_map { |pin| Support.machine_paths(Support.project_paths(pin.input, destination)) }.uniq
      paths.map do |path|
        "branchout: the emitted test passes #{path}, a file of this machine outside the test's project, so the test passes " \
          "only here. Put the file under the project, and the test names it from its own directory."
      end
    end

    # +pin_keys+ names the keys a returned Hash pins; empty pins it whole.
    def render(format, result, target, destination, require_by_name: false, pin_keys: [])
      pins = result.pins.map { |pin| pin.dup.tap { |copy| copy.input = Support.project_paths(pin.input, destination) } }
      emitter_for(format).render(result.dup.tap { |copy| copy.pins = pins }, target, destination,
                                 require_by_name: require_by_name, pin_keys: pin_keys)
    end

    def emitter_for(format)
      case resolve(format, nil)
      when "minitest" then Minitest
      when "rspec" then RSpec
      end
    end
  end
end
