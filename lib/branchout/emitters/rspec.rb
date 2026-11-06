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
      # rspec puts these on the load path of a run from the project root.
      RUNNER_LOAD_PATHS = %w[spec lib].freeze
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

      def render(result, target, destination, require_by_name: false, pin_keys: [], from: Dir.pwd, all_varied: false)
        lines = Support.header(target, "specs", destination)
        lines << ""
        lines.concat(Support.require_lines(result.requires, (target.path unless result.target_required), destination,
                                          by_name: require_by_name, load_paths: result.load_paths,
                                          runner_load_paths: RUNNER_LOAD_PATHS, from: from))
        lines << ""
        const = result.const_expression || target.const_name
        type = ", type: #{result.spec_type.inspect}" if result.spec_type.is_a?(Symbol)
        # A private constant cannot be named bare at load time, so the
        # describe names it as text.
        lines << "RSpec.describe #{const == target.const_name ? const : target.const_name.inspect}#{type} do"
        lines << "  describe #{"#{target.singleton ? "." : "#"}#{target.method_name}".inspect} do"
        if result.pins.empty?
          lines << "    it #{(all_varied ? "pins no input" : "discovers no inputs").inspect} do"
          lines << "      skip #{Support.no_pin_reason(all_varied).inspect}"
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
          # The describe names the class, so rubocop-rspec's
          # RSpec/DescribedClass wants it as described_class. A private
          # constant is described by its name, which leaves described_class nil.
          @const = const == target.const_name ? "described_class" : const
          @private_calls = private_calls
          @pin_keys = pin_keys
          @receiver = receiver_name
          @subject = subject_name if pins.all? { |pin| pin.input.args.empty? && pin.input.kwargs.empty? && pin.input.block.nil? }
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
            befores.each { |step| step.code.each_line(chomp: true) { |line| out << "#{indent}  #{line}" } }
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
          lines.concat(Support.thawed_comment(pin, "#{indent}  "))
          inline = example.steps.select { |step| step.kind == :inline }.map(&:code)
          call = @subject || (@subject == false ? "subject" : entry_call(pin.input, pin.thawed))
          if pin.error
            if inline.empty?
              lines << "#{indent}  expect { #{call} }.to #{error_matcher(pin.error)}"
            else
              lines << "#{indent}  expect {"
              (inline + [call]).each { |line| lines << "#{indent}    #{line}" }
              lines << "#{indent}  }.to #{error_matcher(pin.error)}"
            end
          else
            lines << "#{indent}  expect(#{call}).to #{value_matcher(pin.value, Support.keys_for(pin, @pin_keys))}"
          end
          lines << "#{indent}end"
        end

        def error_matcher(error)
          if error.name
            "raise_error(#{error.class_name}) { |error| expect(error.name).to eq(#{error.name.inspect}) }"
          elsif error.stable_message
            "raise_error(#{error.class_name}, #{Support.ruby_literal(error.exact_message || error.message)})"
          elsif error.message_pattern
            "raise_error(#{error.class_name}, #{Regexp.new(error.message_pattern).inspect})"
          else
            "raise_error(#{error.class_name})"
          end
        end

        def value_matcher(value, pin_keys)
          pinned = Support.pinned_value(value, pin_keys)
          unless pinned.equal?(value)
            return "include(#{Support.literal?(pinned) ? Support.ruby_literal(pinned) : Support.shape_matcher(pinned)})"
          end
          return "match(#{Support.frame_pattern(value)})" if Support.frame_pattern(value)
          unless Support.literal?(value)
            return "match(#{Support.shape_matcher(value)})" if value.is_a?(Array) || value.is_a?(Hash)
            return Support.shape_matcher(value) if value.is_a?(Struct) || value.is_a?(Data)

            return "be_a(#{Support.class_literal(value)})"
          end

          # rubocop-rspec's RSpec/BeEq and RSpec/BeNil.
          return "be_nil" if value.nil?
          return "be(#{value})" if value == true || value == false

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
            [member, text.length > LIMIT ? fitted(member, telling(steps, others), peers) : text]
          end
          repeated = texts.values.tally
          texts.to_h do |member, text|
            next [member, text] if repeated[text] == 1

            digest = " (input #{Digest::SHA256.hexdigest(pins_of(member).first.input.canonical)[0, 6]})"
            [member, text.length + digest.length > LIMIT ? "#{cut_after(text, kept_start(member, text), LIMIT - digest.length)}#{digest}" : "#{text}#{digest}"]
          end
        end

        # +text+ cut to +limit+ characters with "...", but never inside its
        # first +kept+ characters.
        def cut_after(text, kept, limit = LIMIT)
          text.length <= limit ? text : "#{text[0, [limit - 3, kept].max]}..."
        end

        # The start of +text+ a cut keeps: an error's class, whole or by its
        # last segment, as +text+ names it.
        def kept_start(member, text)
          return 0 unless member.is_a?(Example) && member.pin.error

          outcome = @short_outcomes[member.pin]
          text.start_with?(outcome) ? outcome.length : last_segment(outcome).length
        end

        def last_segment(outcome) = outcome.sub(/\Araises (?:\w+::)+/, "raises ")

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

        # A text still over LIMIT. An example cuts its outcome, which leads,
        # and keeps whole the facts that tell it from its siblings, while the
        # outcome keeps a start to read; otherwise the end is cut.
        # An error's class is never cut, since a reader looks it up, but it
        # gives way to its last segment before the facts after it are cut.
        def fitted(member, steps, peers)
          text = member_text(member, steps, peers, short: true)
          facts = label(steps, peers, short: true)
          if member.is_a?(Example) && member.pin.error
            outcome = @short_outcomes[member.pin]
            last = last_segment(outcome)
            return cut_after("#{last}#{text[outcome.length..]}", last.length)
          end
          room = LIMIT - facts.length - " ...".length
          return "#{text[0, LIMIT - 3]}..." unless member.is_a?(Example) && !facts.empty? && room >= 12

          "#{@short_outcomes[member.pin][0, room]}... #{facts}"
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
          calls = steps.select { |step| CALLS.include?(step.kind) }.map { |step| call_label(step, peers) }
          facts = steps.select { |step| step.kind == :fact }.map { |step| fact_label(step.leaf, peers, short: short) }
          parts = receiver
          parts += ["after #{series(calls)}"] unless calls.empty?
          parts += ["when #{series(facts)}"] unless facts.empty?
          parts.join(" ")
        end

        # An input's before that calls the method a sibling's before calls,
        # with other keywords, is named by the keywords that differ:
        # create(:part) with size: 1. A before of several statements is
        # named by the statements that differ from a sibling's of as many
        # statements, each in that way. Any other step is named by its
        # source, on one line.
        def call_label(step, peers)
          return step.label unless step.leaf

          mine = Support.statements(step.leaf[1])
          others = peers.filter_map { |pin| pin.input.before }.uniq.reject { |code| code == step.leaf[1] }
                        .map { |code| Support.statements(code) }.select { |statements| statements.length == mine.length }
          telling = mine.each_index.select { |index| others.any? { |other| other[index] != mine[index] } }
          return step.label if telling.empty? || telling.length == mine.length && mine.length > 1

          series(telling.map { |index| keyword_label(mine[index], others.map { |other| other[index] }) })
        end

        def keyword_label(code, others)
          head, *keywords = Support.call_parts(code)
          others = others.reject { |other| other == code }.map { |other| Support.call_parts(other) }
                         .select { |parts| parts.first == head }.map { |parts| parts.drop(1).to_h }
          differing = keywords.select { |key, value| others.any? { |other| !other.key?(key) || !other[key].eql?(value) } }
          return code.source if differing.empty?

          texts = differing.map { |key, value| "#{key}: #{value.is_a?(Code) ? value.source : value_text(value, [])}" }
          "#{head[1].source} with #{texts.join(", ")}"
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
            steps << Step.new(:before, Support.statements(input.before).map(&:source).join("; "), input.before.source, [[:before], input.before]) if input.before
            unless @target.singleton
              steps << Step.new(:let, receiver_label(input), Support.receiver_text(input, @const, @private_calls, thawed: pin.thawed))
            end
            # A setup call that may be the one that raised stays inside the
            # expect block, so the example still pins the error.
            kind = pin.error ? :inline : :before
            input.setup.each do |call|
              plain = Support.argument_list(call.arguments)
              code = Support.call_text(receiver_expression, call.method_name, Support.argument_list(call.arguments, thawed: pin.thawed), [])
              steps << Step.new(kind, "#{call.method_name}#{"(#{plain})" unless plain.empty?}", code)
            end
            steps + fact_steps(input)
          end
        end

        # A fact names its leaf by a path into the argument (args[0].value),
        # and an Array of scalars as a whole (items is [1, 2]). When every
        # input passes one argument and no keyword, a path that starts at a
        # key inside that argument says enough, and the parameter's name is
        # left out; a path that starts at a position keeps it (items[0].sku).
        def fact_steps(input)
          names = parameter_names
          leaves = []
          input.args.each_with_index do |arg, index|
            Support.collect_leaves(arg, [names[index] || "argument #{index + 1}"], leaves, whole_arrays: true)
          end
          input.kwargs.each { |key, value| Support.collect_leaves(value, [key], leaves, whole_arrays: true) }
          leaves << [["block"], input.block] if input.block
          leaves.map { |leaf| Step.new(:fact, fact_label(leaf), nil, leaf) }
        end

        # +short+ names the leaf from its deepest key, as a minitest name
        # does, for a text that is still too long: status is "failed". A key
        # that ends another leaf's path too keeps the keys above it. A path
        # that would start at a bracket names the argument and the literal
        # that holds the leaf, doc holds "status" => "failed", since
        # doc["status"] would name another leaf.
        def fact_label(leaf, peers = [], short: false)
          (root, *path), value = leaf
          value = value_text(value, peer_values(leaf, peers))
          telling = Support.telling_path(path, peer_paths(root, peers)) if short && path.any? { |step| Support.key_step?(step) }
          if telling && telling.length < path.length
            return "#{root} holds #{Support.entries_text([[telling, value]])}" if Support.path_text(telling).start_with?("[")

            return "#{Support.path_text(telling)} is #{value}"
          end
          name = Support.path_text(path)
          name = Support.path_text(path, root) if !@one_argument || name.empty? || name.start_with?("[")
          "#{name} is #{value}"
        end

        # A value longer than 30 characters is cut. A String is cut where it
        # parts from the other Strings at its leaf, so two values that share
        # a long start do not read alike.
        def value_text(value, peer_values)
          value = Support.described(value)
          peer_values = peer_values.map { |other| Support.described(other) }
          text = Support.ruby_literal(value)
          return text if text.length <= 30
          return "#{text[0, 27]}..." unless value.is_a?(String)

          parts = peer_values.grep(String).reject { |other| other == value }.map do |other|
            value.each_char.zip(other.each_char).take_while { |mine, theirs| mine == theirs }.length
          end
          start = (parts.max || 0) < 20 ? 0 : parts.max - 10
          # Start at a word or a path segment when one begins shortly before.
          separator = value.rindex(%r{[\s/]}, start)
          start = separator + 1 if start.positive? && separator && start - separator <= 12
          # An end "..." that would stand for no more than its own three
          # characters keeps the end instead.
          length = value.length - start <= 25 ? 25 : 22
          finish = Support.word_end(value, start, start + length)
          Support.ruby_literal("#{"..." if start.positive?}#{value[start...finish]}#{"..." if finish < value.length}")
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

        # "with new(10)", or "with create(:loan)" for a receiver the input builds.
        def receiver_label(input)
          return "with #{input.receiver.source}" if input.receiver.is_a?(Code)

          plain = input.receiver ? Support.argument_list(input.receiver) : ""
          plain.empty? ? "with new" : "with new(#{plain})"
        end

        def receiver_expression
          @target.singleton ? @const : @receiver
        end

        def entry_call(input = nil, thawed = false)
          arguments = input ? Support.argument_list(input, thawed: thawed) : ""
          Support.with_block(Support.call_text(receiver_expression, @target.method_name, arguments, @private_calls), input&.block)
        end

        def receiver_name
          Support.built_receiver_name(@target)
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
