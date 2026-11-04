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
      # A fact runs no code; its +leaf+ is the [path, value] it names, so
      # two values whose labels are cut alike stay two facts.
      Step = Data.define(:kind, :label, :code, :leaf) do
        def initialize(kind:, label:, code: nil, leaf: nil) = super
      end
      # The longest description or context text.
      LIMIT = 80
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
        const = result.const_expression || target.const_name
        # A private constant cannot be named bare at load time, so the
        # describe names it as text.
        lines << "RSpec.describe #{const == target.const_name ? const : target.const_name.inspect} do"
        lines << "  describe #{"#{target.singleton ? "." : "#"}#{target.method_name}".inspect} do"
        if result.pins.empty?
          lines << '    it "discovers no inputs" do'
          lines << '      skip "branchout did not discover an input"'
          lines << "    end"
        else
          spec = Spec.new(target, result.pins, result.private_calls, pin_keys, const)
          lines.concat(spec.lines)
        end
        lines << "  end"
        lines << "end"
        "#{lines.join("\n")}\n"
      end

      # The describe block of one entry: its subject, its tree of contexts,
      # and the examples.
      class Spec
        def initialize(target, pins, private_calls, pin_keys, const = target.const_name)
          @target = target
          @const = const
          @private_calls = private_calls
          @pin_keys = pin_keys
          @receiver = receiver_name
          @subject = subject_name if pins.all? { |pin| pin.input.args.empty? && pin.input.kwargs.empty? }
          @one_argument = pins.all? { |pin| pin.input.args.length == 1 && pin.input.kwargs.empty? }
          @outcomes = Support.outcomes(pins, pin_keys)
          @short_outcomes = Support.outcomes(pins, pin_keys, short: true)
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
          texts = member_texts(node.members)
          node.members.each do |member|
            out << "" unless out.empty?
            if member.is_a?(Example)
              out.concat(example_lines(member, texts[member], indent))
            else
              out << "#{indent}context #{quoted(texts[member])} do"
              out.concat(node_lines(member, "#{indent}  "))
              out << "#{indent}end"
            end
          end
          out
        end

        def example_lines(example, text, indent)
          pin = example.pin
          lines = ["#{indent}it #{quoted(text)} do"]
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
            "raise_error(#{error.class_name}, #{(error.exact_message || error.message).inspect})"
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

        # The text of each member of one group, at most LIMIT characters. A
        # context, and a member whose text is longer, says only the facts
        # that tell it from its siblings; a text still too long names them
        # by their deepest key, then is cut. Texts that would still be the
        # same end in their first input's digest.
        def member_texts(members)
          peers = members.flat_map { |member| pins_of(member) }
          texts = members.to_h do |member|
            others = members.reject { |other| other.equal?(member) }.flat_map { |other| pins_of(other) }
            steps = member.is_a?(Example) ? member.facts : member.steps
            text = member_text(member, steps, peers)
            text = member_text(member, telling(steps, others), peers) if text.length > LIMIT || member.is_a?(Node)
            text = member_text(member, telling(steps, others), peers, short: true) if text.length > LIMIT
            [member, text.length > LIMIT ? "#{text[0, LIMIT - 3]}..." : text]
          end
          repeated = texts.values.tally
          texts.to_h do |member, text|
            next [member, text] if repeated[text] == 1

            digest = " (input #{Digest::SHA256.hexdigest(pins_of(member).first.input.canonical)[0, 6]})"
            [member, text.length + digest.length > LIMIT ? "#{text[0, LIMIT - digest.length - 3]}...#{digest}" : "#{text}#{digest}"]
          end
        end

        # +steps+ without the facts that tell no sibling apart: the fewest
        # facts, in their order, that each sibling input in +others+ lacks
        # one of. A context keeps at least one fact.
        def telling(steps, others)
          facts = steps.select { |step| step.kind == :fact }
          left = others.reject { |pin| (facts - steps_of(pin)).empty? }
          chosen = []
          until left.empty?
            best = facts.max_by { |fact| [left.count { |pin| !steps_of(pin).include?(fact) }, -facts.index(fact)] }
            break if best.nil? || chosen.include?(best)

            chosen << best
            left.reject! { |pin| !steps_of(pin).include?(best) }
          end
          chosen = facts.first(1) if chosen.empty? && steps.none? { |step| step.kind != :fact }
          steps.reject { |step| step.kind == :fact && !chosen.include?(step) }
        end

        def member_text(member, steps, peers, short: false)
          text = label(steps, peers, short: short)
          return text unless member.is_a?(Example)

          outcome = (short ? @short_outcomes : @outcomes)[member.pin]
          text.empty? ? outcome : "#{outcome} #{text}"
        end

        # A text as a literal that needs no escape, so it reads as it prints:
        # 'when kind is "int"', or %q(...) when it holds both quotes.
        def quoted(text)
          plain = text.inspect
          # Single quotes and %q read only a doubled backslash or their own
          # delimiter as an escape, so a text that a value's own literal put
          # a backslash in still reads as written.
          literal = text.match?(/\A[[:print:]]*\z/) && !text.include?("\\\\") && !text.end_with?("\\")
          return plain unless text.include?('"') && literal
          return "'#{text}'" unless text.include?("'")
          return "%q(#{text})" unless text.match?(/[()]/)

          plain
        end

        def pins_of(member)
          member.is_a?(Example) ? [member.pin] : member.members.flat_map { |inner| pins_of(inner) }
        end

        # "with new(10) after add("apple", 3) when price is 5": the receiver,
        # the calls, then the facts.
        def label(steps, peers = [], short: false)
          receiver = steps.select { |step| step.kind == :let }.map(&:label)
          calls = steps.select { |step| CALLS.include?(step.kind) }.map(&:label)
          facts = steps.select { |step| step.kind == :fact }.map { |step| fact_label(step.leaf, peers, short: short) }
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
              code = Support.call_text(@const, :new, arguments, @private_calls)
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
          leaves.map { |leaf| Step.new(:fact, fact_label(leaf), nil, leaf) }
        end

        # +short+ names the leaf from its deepest key (status), as a
        # minitest name does, for a text that is still too long. A key that
        # ends another leaf's path too keeps the keys above it.
        def fact_label(leaf, peers = [], short: false)
          (root, *path), value = leaf
          deepest = path.rindex { |step| step.is_a?(String) }
          name = if short && deepest then Support.path_text(Support.telling_path(path, peer_paths(root, peers)))
                 elsif path.empty? || !@one_argument then Support.path_text(path, root)
                 else Support.path_text(path)
                 end
          "#{name} is #{value_text(value, peer_values(leaf, peers))}"
        end

        # A value longer than 30 characters is cut. A String is cut where it
        # parts from the other Strings at its leaf, so two values that share
        # a long start do not read alike.
        def value_text(value, peer_values)
          text = Support.ruby_literal(value)
          return text if text.length <= 30
          return "#{text[0, 27]}..." unless value.is_a?(String)

          parts = peer_values.grep(String).reject { |other| other == value }.map do |other|
            value.each_char.zip(other.each_char).take_while { |mine, theirs| mine == theirs }.length
          end
          start = (parts.max || 0) < 20 ? 0 : parts.max - 10
          # Start at a word when one begins shortly before.
          space = value.rindex(/\s/, start)
          start = space + 1 if start.positive? && space && start - space <= 12
          piece = value[start, 22]
          Support.ruby_literal("#{"..." if start.positive?}#{piece}#{"..." if start + 22 < value.length}")
        end

        def peer_paths(root, peers)
          peers.flat_map { |pin| steps_of(pin).filter_map { |step| step.leaf[0].drop(1) if step.kind == :fact && step.leaf[0][0] == root } }.uniq
        end

        def peer_values(leaf, peers)
          peers.flat_map { |pin| steps_of(pin).filter_map { |step| step.leaf[1] if step.kind == :fact && step.leaf[0] == leaf[0] } }
        end

        def parameter_names
          return [] unless @target.respond_to?(:positional) && @target.parameters

          @target.positional.map { |param| param.name.to_s }
        end

        def receiver_expression
          @target.singleton ? @const : @receiver
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
