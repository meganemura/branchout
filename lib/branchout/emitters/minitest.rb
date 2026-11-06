# frozen_string_literal: true

module Branchout
  module Emitters
    module Minitest
      module_function

      def render(result, target, destination, require_by_name: false, pin_keys: [], from: Dir.pwd, all_varied: false)
        lines = Support.header(target, "tests", destination)
        lines << ""
        lines << 'require "minitest/autorun"'
        lines.concat(Support.require_lines(result.requires, (target.path unless result.target_required), destination,
                                          by_name: require_by_name, load_paths: result.load_paths, from: from))
        lines << ""
        lines << "class #{Support.class_name_for(target)} < #{result.test_class || "Minitest::Test"}"
        if result.pins.empty?
          lines << "  def #{all_varied ? "test_no_input_pinned" : "test_no_inputs_discovered"}"
          lines << "    skip #{Support.no_pin_reason(all_varied).inspect}"
          lines << "  end"
        else
          names = Support.test_names(result.pins, pin_keys)
          result.pins.each_with_index do |pin, index|
            lines << "" unless index.zero?
            lines.concat(example_lines(target, pin, names[index], result.private_calls, pin_keys, result.const_expression || target.const_name))
          end
        end
        lines << "end"
        "#{lines.join("\n")}\n"
      end

      def example_lines(target, pin, name, private_calls, pin_keys, const = target.const_name)
        lines = ["  def #{name}"]
        lines.concat(Support.cover_comment(pin, "    "))
        lines.concat(Support.thawed_comment(pin, "    "))
        arrange, call = Support.arrange(target, pin.input, private_calls: private_calls, const: const, thawed: pin.thawed)
        if pin.error
          lines << "    error = assert_raises(#{pin.error.class_name}) do"
          lines.concat(Support.indent(arrange + [call], "      "))
          lines << "    end"
          if pin.error.name
            lines << "    assert_equal #{pin.error.name.inspect}, error.name"
          elsif pin.error.stable_message
            lines << "    assert_equal #{Support.ruby_literal(pin.error.exact_message || pin.error.message)}, error.message"
          elsif pin.error.message_pattern
            lines << "    assert_match(#{Regexp.new(pin.error.message_pattern).inspect}, error.message)"
          end
          return lines << "  end"
        end

        lines.concat(Support.indent(arrange, "    "))
        pinned = Support.pinned_value(pin.value, Support.keys_for(pin, pin_keys))
        if !pinned.equal?(pin.value) && Support.literal?(pinned)
          keys = pinned.keys.map { |key| Support.ruby_literal(key) }.join(", ")
          lines << "    assert_equal(#{Support.ruby_literal(pinned)}, #{call}.slice(#{keys}))"
        elsif !pinned.equal?(pin.value)
          lines.concat(part_lines(pinned, call))
        elsif pin.value.nil?
          # Minitest 6 fails assert_equal with an expected nil.
          lines << "    assert_nil #{call}"
        elsif (pattern = Support.frame_pattern(pin.value))
          lines << "    assert_match(#{pattern}, #{call})"
        elsif pin.value.is_a?(Hash) && Support.literal?(pin.value)
          # Without parentheses Ruby reads a leading { as a block.
          lines << "    assert_equal(#{Support.ruby_literal(pin.value)}, #{call})"
        elsif Support.literal?(pin.value)
          lines << "    assert_equal #{Support.ruby_literal(pin.value)}, #{call}"
        elsif Support.class_pins(pin.value) == [["", Support.class_literal(pin.value)]]
          lines << "    assert_kind_of #{Support.class_literal(pin.value)}, #{call}"
        else
          lines << "    value = #{call}"
          lines.concat(Support.shape_assertions(pin.value).map { |line| "    #{line}" })
        end
        lines << "  end"
        lines
      end

      # The stable keys of a Hash with no literal: its literal entries by
      # value, and each other one by its shape, as RSpec's include pins it.
      # The call runs once, since a second call could make another record.
      def part_lines(pinned, call)
        literal, other = pinned.partition { |_, item| Support.literal?(item) }.map(&:to_h)
        lines = ["    value = #{call}"]
        unless literal.empty?
          keys = literal.keys.map { |key| Support.ruby_literal(key) }.join(", ")
          lines << "    assert_equal(#{Support.ruby_literal(literal)}, value.slice(#{keys}))"
        end
        other.each { |key, item| lines.concat(Support.shape_assertions(item, "[#{Support.ruby_literal(key)}]").map { |line| "    #{line}" }) }
        lines
      end
    end
  end
end
