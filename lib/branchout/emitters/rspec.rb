# frozen_string_literal: true

module Branchout
  module Emitters
    # Emits RSpec source. This file does not load the rspec gem.
    module RSpec
      module_function

      def write(result, target, destination)
        Support.write_file(destination, render(result, target, destination))
      end

      def render(result, target, destination)
        relative = Support.relative_require(destination, target.path)
        lines = Support.header(target, "specs")
        lines << ""
        result.requires.each { |path| lines << "require_relative #{Support.relative_require(destination, path).inspect}" }
        lines << "require_relative #{relative.inspect}"
        lines << ""
        lines << "RSpec.describe #{target.entry.inspect} do"
        if result.pins.empty?
          lines << '  it "discovers no inputs" do'
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
        lines = ["  it #{format("%03d", index).inspect} do"]
        lines.concat(Support.cover_comment(pin, "    "))
        arrange, call = Support.arrange(target, pin.input)
        if pin.error
          matcher = if pin.error.name
            "raise_error(#{pin.error.class_name}) { |error| expect(error.name).to eq(#{pin.error.name.inspect}) }"
          elsif pin.error.stable_message
            "raise_error(#{pin.error.class_name}, #{pin.error.message.inspect})"
          else
            "raise_error(#{pin.error.class_name})"
          end
          if arrange.empty?
            lines << "    expect { #{call} }.to #{matcher}"
          else
            lines << "    expect {"
            (arrange + [call]).each { |line| lines << "      #{line}" }
            lines << "    }.to #{matcher}"
          end
          return lines << "  end"
        end

        arrange.each { |line| lines << "    #{line}" }
        if Support.literal?(pin.value)
          lines << "    expect(#{call}).to eq(#{Support.ruby_literal(pin.value)})"
        else
          lines << "    expect(#{call}).to be_a(#{Support.class_literal(pin.value)})"
        end
        lines << "  end"
        lines
      end
    end
  end
end
