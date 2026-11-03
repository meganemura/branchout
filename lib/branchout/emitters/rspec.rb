# frozen_string_literal: true

module Branchout
  module Emitters
    # Emits RSpec source. This file does not load the rspec gem.
    #
    # Each input becomes a list of steps: the receiver (a let), each setup
    # call (a before, or inline when the input raised), and each leaf of the
    # arguments (a fact, which only names). Inputs that start with the same
    # steps share a context that holds them, so an example is left with the
    # outcome and the facts of its own.
    module RSpec
      Step = Data.define(:kind, :label, :code)
      CALLS = %i[before inline].freeze
      # The steps whose code runs in a context, so an input that still has
      # one gets a context of its own.
      CONTEXT_STEPS = %i[let before].freeze
      Node = Data.define(:steps, :members)
      Example = Data.define(:pin, :steps, :facts)

      # Names that a let or a subject must not take: RSpec's own methods.
      TAKEN_NAMES = %w[
        subject example expect is_expected described_class context describe let before after it
        raise_error eq include be_a skip pending
      ].freeze

      module_function

      def render(result, target, destination, require_by_name: false, pin_keys: [])
        lines = Support.header(target, "specs", destination)
        lines << ""
        lines.concat(Support.require_lines(result.requires, (target.path unless result.target_required), destination, by_name: require_by_name))
        lines << ""
        lines << "RSpec.describe #{target.const_name} do"
        lines << "  describe #{"#{target.singleton ? "." : "#"}#{target.method_name}".inspect} do"
        if result.pins.empty?
          lines << '    it "discovers no inputs" do'
          lines << '      skip "branchout did not discover an input"'
          lines << "    end"
        else
          spec = Spec.new(target, result.pins, result.private_calls, pin_keys)
          lines.concat(spec.lines)
        end
        lines << "  end"
        lines << "end"
        "#{lines.join("\n")}\n"
      end

      # The describe block of one entry: its subject, its tree of contexts,
      # and the examples.
      class Spec
        def initialize(target, pins, private_calls, pin_keys)
          @target = target
          @private_calls = private_calls
          @pin_keys = pin_keys
          @receiver = receiver_name
          @subject = subject_name if pins.all? { |pin| pin.input.args.empty? && pin.input.kwargs.empty? }
          @one_argument = pins.all? { |pin| pin.input.args.length == 1 && pin.input.kwargs.empty? }
          @outcomes = Support.outcomes(pins, pin_keys)
          entries = pins.map { |pin| [pin, steps_of(pin)] }
          shared = entries.map { |_, steps| steps.select { |step| step.kind == :fact } }.reduce(:&)
          entries = entries.map { |pin, steps| [pin, steps - shared] }
          @root = merged(build([], entries))
        end

        def lines
          out = case @subject
            when String then ["    subject(:#{@subject}) { #{entry_call} }", ""]
            when false then ["    subject { #{entry_call} }", ""]
            else []
          end
          out + node_lines(@root, "    ")
        end

        private

        def node_lines(node, indent)
          out = []
          node.steps.select { |step| step.kind == :let }.each do |step|
            out << "#{indent}let(:#{@receiver}) { #{step.code} }"
          end
          befores = node.steps.select { |step| step.kind == :before }
          unless befores.empty?
            out << "" unless out.empty?
            out << "#{indent}before do"
            befores.each { |step| out << "#{indent}  #{step.code}" }
            out << "#{indent}end"
          end
          descriptions = node.members.grep(Example).to_h { |example| [example, description(example)] }
          repeated = descriptions.values.tally
          node.members.each do |member|
            out << "" unless out.empty?
            if member.is_a?(Example)
              text = descriptions[member]
              text += " (input #{Digest::SHA256.hexdigest(member.pin.input.canonical)[0, 6]})" if repeated[text] > 1
              out.concat(example_lines(member, text, indent))
            else
              out << "#{indent}context #{label(member.steps).inspect} do"
              out.concat(node_lines(member, "#{indent}  "))
              out << "#{indent}end"
            end
          end
          out
        end

        def example_lines(example, text, indent)
          pin = example.pin
          lines = ["#{indent}it #{text.inspect} do"]
          lines.concat(Support.cover_comment(pin, "#{indent}  "))
          inline = example.steps.select { |step| step.kind == :inline }.map(&:code)
          call = @subject || (@subject == false ? "subject" : entry_call(pin.input))
          if pin.error
            if inline.empty?
              lines << "#{indent}  expect { #{call} }.to #{error_matcher(pin.error)}"
            else
              lines << "#{indent}  expect {"
              (inline + [call]).each { |line| lines << "#{indent}    #{line}" }
              lines << "#{indent}  }.to #{error_matcher(pin.error)}"
            end
          else
            lines << "#{indent}  expect(#{call}).to #{value_matcher(pin.value)}"
          end
          lines << "#{indent}end"
        end

        def error_matcher(error)
          if error.name
            "raise_error(#{error.class_name}) { |error| expect(error.name).to eq(#{error.name.inspect}) }"
          elsif error.stable_message
            "raise_error(#{error.class_name}, #{error.message.inspect})"
          else
            "raise_error(#{error.class_name})"
          end
        end

        def value_matcher(value)
          pinned = Support.pinned_value(value, @pin_keys)
          return "include(#{Support.ruby_literal(pinned)})" if !pinned.equal?(value) && Support.literal?(pinned)
          unless Support.literal?(value)
            return "match(#{Support.shape_matcher(value)})" if value.is_a?(Array) || value.is_a?(Hash)
            return Support.shape_matcher(value) if value.is_a?(Struct) || value.is_a?(Data)

            return "be_a(#{Support.class_literal(value)})"
          end

          "eq(#{Support.ruby_literal(value)})"
        end

        def description(example)
          rest = label(example.facts)
          rest.empty? ? @outcomes[example.pin] : "#{@outcomes[example.pin]} #{rest}"
        end

        # "with new(10) after add("apple", 3) when price is 5": the receiver,
        # the calls, then the facts.
        def label(steps)
          receiver = steps.select { |step| step.kind == :let }.map(&:label)
          calls = steps.select { |step| CALLS.include?(step.kind) }.map(&:label)
          facts = steps.select { |step| step.kind == :fact }.map(&:label)
          parts = receiver
          parts += ["after #{series(calls)}"] unless calls.empty?
          parts += ["when #{series(facts)}"] unless facts.empty?
          parts.join(" ")
        end

        def series(words)
          words.length < 2 ? words.join : "#{words[0..-2].join(", ")} and #{words.last}"
        end

        # Groups +entries+ by their first step, in the order they appear. An
        # entry left with only facts, or none, is an example; the rest share
        # a node. Examples come before nodes.
        def build(steps, entries)
          members = []
          groups = entries.group_by { |_, rest| rest.first }
          groups.each do |first, group|
            if group.one? && group.first[1].none? { |step| CONTEXT_STEPS.include?(step.kind) }
              pin, rest = group.first
              members << Example.new(pin, steps_of(pin), rest)
            elsif first.nil?
              group.each { |pin, _| members << Example.new(pin, steps_of(pin), []) }
            else
              members << merged(build([first], group.map { |pin, rest| [pin, rest.drop(1)] }))
            end
          end
          Node.new(steps, members.partition { |member| member.is_a?(Example) }.flatten)
        end

        # A node whose one member is a node takes that node's steps and
        # members, so a chain of single contexts reads as one.
        def merged(node)
          while node.members.one? && node.members.first.is_a?(Node)
            node = Node.new(node.steps + node.members.first.steps, node.members.first.members)
          end
          node
        end

        def steps_of(pin)
          @steps ||= {}
          @steps[pin] ||= begin
            input = pin.input
            steps = []
            unless @target.singleton
              arguments = input.receiver ? Support.argument_list(input.receiver) : ""
              plain = input.receiver ? Support.argument_list(input.receiver, mutable: false) : ""
              code = Support.call_text(@target.const_name, :new, arguments, @private_calls)
              steps << Step.new(:let, plain.empty? ? "with new" : "with new(#{plain})", code)
            end
            # A setup call that may be the one that raised stays inside the
            # expect block, so the example still pins the error.
            kind = pin.error ? :inline : :before
            input.setup.each do |call|
              plain = Support.argument_list(call.arguments, mutable: false)
              code = Support.call_text(receiver_expression, call.method_name, Support.argument_list(call.arguments), [])
              steps << Step.new(kind, "#{call.method_name}#{"(#{plain})" unless plain.empty?}", code)
            end
            steps + fact_steps(input)
          end
        end

        # A fact names its leaf by a path into the argument (args[0].value).
        # When every input passes one argument and no keyword, the path
        # inside that argument says enough, and the parameter's name is
        # left out.
        def fact_steps(input)
          names = parameter_names
          leaves = []
          input.args.each_with_index { |arg, index| Support.collect_leaves(arg, [names[index] || "argument #{index + 1}"], leaves) }
          input.kwargs.each { |key, value| Support.collect_leaves(value, [key], leaves) }
          leaves.map do |(root, *path), value|
            name = path.empty? || !@one_argument ? Support.path_text(path, root) : Support.path_text(path)
            text = Support.ruby_literal(value)
            text = "#{text[0, 27]}..." if text.length > 30
            Step.new(:fact, "#{name} is #{text}", nil)
          end
        end

        def parameter_names
          return [] unless @target.respond_to?(:positional) && @target.parameters

          @target.positional.map { |param| param.name.to_s }
        end

        def receiver_expression
          @target.singleton ? @target.const_name : @receiver
        end

        def entry_call(input = nil)
          arguments = input ? Support.argument_list(input) : ""
          Support.call_text(receiver_expression, @target.method_name, arguments, @private_calls)
        end

        def receiver_name
          name = Support.receiver_name(@target)
          name == "subject" || TAKEN_NAMES.include?(name) ? "object" : name
        end

        # The method's name, when it reads as a plain local name; false for
        # an unnamed subject.
        def subject_name
          name = @target.method_name.to_s
          return false unless name.match?(/\A[a-z_][a-z0-9_]*[?!]?\z/)
          return false if name == @receiver || TAKEN_NAMES.include?(name) || Support::RESERVED_NAMES.include?(name)

          name
        end
      end
    end
  end
end
