# frozen_string_literal: true

module Branchout
  module Emitters
    module Minitest
      module_function

      def write(result, target, destination)
        Support.write_file(destination, render(result, target, destination))
      end

      def render(result, target, destination)
        relative = Support.relative_require(destination, target.path)
        lines = Support.header(target, "tests")
        lines << ""
        lines << 'require "minitest/autorun"'
        result.requires.each { |path| lines << "require_relative #{Support.relative_require(destination, path).inspect}" }
        lines << "require_relative #{relative.inspect}"
        lines << ""
        lines << "class #{Support.class_name_for(target)} < Minitest::Test"
        if result.pins.empty?
          lines << "  def test_no_inputs_discovered"
          lines << '    skip "branchout did not discover an input"'
          lines << "  end"
        else
          result.pins.each_with_index do |pin, index|
            lines << "" unless index.zero?
            lines.concat(example_lines(target, pin, index + 1))
          end
        end
        lines << "end"
        "#{lines.join("\n")}\n"
      end

      def example_lines(target, pin, index)
        lines = ["  def test_#{format("%03d", index)}"]
        lines.concat(Support.cover_comment(pin, "    "))
        call = Support.render_call(target, pin.input)
        if pin.error
          lines << "    error = assert_raises(#{pin.error.class_name}) do"
          lines << "      #{call}"
          lines << "    end"
          if pin.error.stable_message
            lines << "    assert_equal #{pin.error.message.inspect}, error.message"
          end
        elsif pin.value.nil?
          # Minitest 6 fails assert_equal with an expected nil.
          lines << "    assert_nil #{call}"
        elsif pin.value.is_a?(Hash) && Support.literal?(pin.value)
          # Without parentheses Ruby reads a leading { as a block.
          lines << "    assert_equal(#{Support.ruby_literal(pin.value)}, #{call})"
        elsif Support.literal?(pin.value)
          lines << "    assert_equal #{Support.ruby_literal(pin.value)}, #{call}"
        else
          lines << "    assert_kind_of #{Support.class_literal(pin.value)}, #{call}"
        end
        lines << "  end"
        lines
      end
    end
  end
end
