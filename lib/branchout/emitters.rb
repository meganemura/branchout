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

    # Returns a warning for each file the test requires by a path out of its
    # project, and for each path of this machine that the test passes
    # as it is (Support.machine_paths), or pins in a returned value or an
    # error message, for the caller to print.
    def write(format, result, target, destination, require_by_name: false, pin_keys: [])
      pins = project_pins(result.pins, destination)
      Support.write_file(destination, render(format, result, target, destination, require_by_name: require_by_name, pin_keys: pin_keys))
      varying = result.pins.select(&:varying).map { |pin| varying_warning(pin, pin_keys) } +
                result.pins.filter_map { |pin| Support.after_pin(pin) }.select(&:varying).map { |pin| after_varying_warning(pin) }
      passed = pins.flat_map { |pin| Support.machine_paths(pin.input) }.uniq
      pinned = pins.flat_map do |pin|
        # A pattern pins the rest of its message as written, paths too.
        message = pin.error.exact_message || pin.error.message if pin.error&.stable_message || pin.error&.message_pattern
        after = Support.after_pin(pin)
        read = Support.pinned_value(after.value, Support.keys_for(after, [])) if after && after.varying != :whole
        Support.machine_paths_in([Support.pinned_value(pin.value, Support.keys_for(pin, pin_keys)), message, read])
      end
      existing, missing = passed.partition { |path| File.exist?(path) }
      outside = Support.required_outside_project(result.requires, (target.path unless result.target_required), destination,
                                                 by_name: require_by_name, load_paths: result.load_paths)
      varying + outside.map do |path|
        "branchout: the emitted test requires #{path} by its path, outside the test's project, so the test runs only where " \
          "that file sits on this machine. Emit the test under that file's project, or #{require_by_name ? "pass -I with a directory that holds it" : "pass --require-by-name"} " \
          "to require it through the load path."
      end + existing.map do |path|
        "branchout: the emitted test passes #{path}, a file of this machine outside the test's project, so the test passes " \
          "only here. Put the file under the project, and the test names it from its own directory."
      end + (missing - pinned).map do |path|
        "branchout: the emitted test passes #{path}, a path of this machine outside the test's project that does not exist, " \
          "so the test holds this machine's directories. Put the path under the project, and the test names it from its own directory."
      end + (pinned.uniq - existing).map do |path|
        "branchout: the emitted test pins #{path}, a path of this machine outside the test's project, in a returned value, " \
          "an error message, or what an after read, so the test passes only here. Give #{target.entry} a path under the project."
      end
    end

    # +pin_keys+ names the keys a returned Hash pins; empty pins it whole.
    # +from+ is the directory the test's runner starts in.
    # A file with no pin says whether no input ran or each one differed
    # between two runs.
    def render(format, result, target, destination, require_by_name: false, pin_keys: [], from: Dir.pwd)
      pins = project_pins(result.pins, destination)
      emitter_for(format).render(result.dup.tap { |copy| copy.pins = pins }, target, destination,
                                 require_by_name: require_by_name, pin_keys: pin_keys, from: from,
                                 all_varied: pins.empty? && result.pins.any?)
    end

    def varying_warning(pin, pin_keys)
      return "branchout: #{pin.input.text} returned a value that differed between two runs, so it has no test." if pin.varying == :whole

      "branchout: #{pin.input.text} returned a Hash whose #{pin.varying.join(", ")} differed between two runs, " \
        "so its test pins only #{Support.keys_for(pin, pin_keys).join(", ")}."
    end

    def after_varying_warning(pin)
      return "branchout: the after #{pin.input.after.source} of #{pin.input.text} read a value that differed between two runs, so its test does not check it." if pin.varying == :whole

      "branchout: the after #{pin.input.after.source} of #{pin.input.text} read a Hash whose #{pin.varying.join(", ")} differed between two runs, " \
        "so its test pins only #{Support.keys_for(pin, []).join(", ")}."
    end

    # Each pin with the paths under the test's project in its input, its
    # returned value, its error message, and what its after read written
    # from the test's file.
    # A pin whose value differed as a whole between two runs is left out.
    def project_pins(pins, destination)
      pins.reject { |pin| pin.varying == :whole }.map do |pin|
        pin.dup.tap do |copy|
          copy.input = Support.project_paths(pin.input, destination)
          copy.value = Support.project_value(pin.value, destination)
          copy.observed = pin.observed.dup.tap { |read| read.value = Support.project_value(read.value, destination) } if pin.observed
          next unless pin.error

          copy.error = pin.error.dup.tap do |error|
            error.message = Support.project_value(error.message, destination)
            error.exact_message = Support.project_value(error.exact_message, destination)
          end
        end
      end
    end

    def emitter_for(format)
      case resolve(format, nil)
      when "minitest" then Minitest
      when "rspec" then RSpec
      end
    end
  end
end
