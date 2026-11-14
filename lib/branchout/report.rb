# frozen_string_literal: true
# rbs_inline: enabled

module Branchout
  module Report
    # @rbs!
    #   # What a group of inputs returned: [shown, Ruby literal or nil, pins].
    #   type returned_row = [String, String?, Array[Engine::Pin]]
    #   # What a group of afters read: [source, shown, Ruby literal or nil, pins].
    #   type after_row = [String, String, String?, Array[Engine::Pin]]
    #   # What the baselines command reports on.
    #   type baselines_info = { target: String, entry: String, seed: Integer, random: Integer, mutate_cap: Integer, timeout: Integer | Float }

    module_function

    # What a sense asks of an input that reaches the decision.
    WANTS = {
      "cond-true" => "makes `%s` true",
      "cond-false" => "makes `%s` false",
      "arm-matched" => "matches `%s`",
      "arm-else" => "matches no branch of `%s`",
      "body-entered" => "enters the loop at `%s`",
      "receiver-present" => "gives `%s` a receiver that is not nil",
      "receiver-nil" => "gives `%s` a nil receiver"
    }.freeze #: Hash[String, String]
    SHOWN_INPUTS = 3 #: Integer

    # The default leads with what to act on: the counts, then each arm an
    # input reached but did not take. The run settings and the covered arms
    # are in +verbose+ and in the JSON.
    #: (Engine::Result, ?tests: String?, ?verbose: bool, ?verbose_flag: String, ?pin_keys: Array[String]) -> String
    def text(result, tests: nil, verbose: false, verbose_flag: "--verbose", pin_keys: [])
      return full_text(result, pin_keys) if verbose

      total = result.covered.length + result.frontier.length
      raised = result.exceptions.length
      lines = [
        "branchout #{result.command} #{result.target} #{result.entry}",
        "covered: #{result.covered.length} of #{total} arms by #{count(result.executions, "input")}",
        "raised: #{raised.zero? ? "none" : count(raised, "input")}"
      ]
      lines << "tests: #{Target.display_path(tests)}" if tests
      frontier_brief(lines, result.frontier)
      returned_brief(lines, returned(Array(result.pins), pin_keys))
      exceptions_brief(lines, result.exceptions)
      after_brief(lines, after(Array(result.pins)), after_unread(Array(result.pins)))
      not_pinned_brief(lines, result.covered.reject(&:pinned))
      pinned_by_class_brief(lines, result.pins, pin_keys) if tests
      not_counted_brief(lines, Array(result.not_counted))
      operators_brief(lines, Array(result.operators))
      boundaries_brief(lines, Array(result.boundaries))
      lines << "" << "Pass #{verbose_flag} for every covered arm and the run settings."
      "#{lines.join("\n")}\n"
    end

    #: (Array[String], Array[Engine::Arm]) -> void
    def frontier_brief(lines, frontier)
      reached, waiting = frontier.partition { |arm| arm.parent == "reached" }
      lines << "" << (reached.any? ? "FRONTIER (add an input like the nearest above each arm, changed as the arm says)" : "FRONTIER")
      lines << "(none: every arm ran, which does not mean each value is right; check RETURNED)" if frontier.empty?
      # Consecutive arms share one nearest line, so a first run's single
      # input is printed once, not once for each arm it reached.
      nearest = ->(arm) { arm.nearest ? arm.nearest.text : "null" }
      reached.sort_by { |arm| [arm.line, arm.column, arm.id] }.chunk_while { |a, b| nearest.(a) == nearest.(b) }.each do |arms|
        lines << "nearest: #{nearest.(arms.first)}"
        arms.each { |arm| lines << "#{arm.loc} #{WANTS.fetch(arm.sense, "takes the arm at `%s`") % arm.cond}" }
      end
      return if waiting.empty?

      lines << "" if reached.any?
      lines << (reached.any? ? "not reached yet; take the arms above first:" : "no input reached these decisions:")
      # An id is "kind@line:column/arm@line:column"; its first half names the decision.
      decisions = waiting.group_by { |arm| arm.id.split("/").first.match(/\A(.+)@(\d+):(\d+)\z/).captures } # steep:ignore NoMethod
      decisions.sort_by { |(_, line, column), _| [line.to_i, column.to_i] }.each do |(kind, line, _), arms|
        file = arms.first.loc.sub(/:\d+:\d+\z/, "")
        conds = arms.map(&:cond).uniq
        lines << "#{file}:#{line} #{conds.one? ? conds.first : kind} (#{count(arms.length, "arm")})"
      end
    end

    #: (Integer, String) -> String
    def count(number, noun)
      "#{number} #{noun}#{"s" unless number == 1}"
    end

    # Coverage counts the arms an input took, never what it returned, so a
    # wrong value in code with no branch of its own shows only here. Each
    # input of the inputs file and each arm's input, grouped by what it
    # returned, as [shown, value, pins]: +value+ is the Ruby literal of the
    # whole value, or nil for one with no literal, and +shown+ fits a line.
    # Both mark a path of this machine (Support.marked) and do not drop
    # it, so neither reads as a value the method did not return.
    #: (Array[Engine::Pin], Array[String]) -> Array[returned_row]
    def returned(pins, pin_keys)
      groups = pins.reject(&:error).group_by do |pin|
        next [:shown, "a value that differed between two runs"] if pin.varying == :whole

        pinned = Emitters::Support.pinned_pin(pin, pin_keys)
        next [:value, pinned.value] if Emitters::Support.literal?(pinned.value)

        shown = shown_hash(pinned.value, []) if Emitters::Support.keyed?(pinned.value)
        [:shown, shown || Emitters::Support.outcome_text(pinned, []).delete_prefix("returns ")]
      end
      values = groups.keys.select { |kind, _| kind == :value }.map(&:last)
      differences = values.zip(Emitters::Support.hash_differences(values)).to_h
      rows = groups.map do |(kind, value), group|
        next [value, nil, group] if kind == :shown

        whole = Emitters::Support.ruby_literal(Emitters::Support.marked(value))
        next [whole, whole, group] if whole.length <= SHOWN_WIDTH

        shown = if Emitters::Support.keyed?(value)
          shown_hash(value, differences.fetch(value)) # steep:ignore ArgumentTypeMismatch
        elsif value.is_a?(Array) || value.is_a?(Struct) || value.is_a?(Data)
          shown_composite(value, values)
        end
        [shown || "#{whole[0, SHOWN_WIDTH - 3]}...", whole, group]
      end
      # Two values that differ only in the directories a mark stands for
      # would read as one value returned twice.
      alike = rows.filter_map { |_, whole, _| whole }.tally
      rows.map { |shown, whole, group| whole && alike[whole] > 1 ? ["#{shown} (another value differs from it in a path of this machine)", whole, group] : [shown, whole, group] } # steep:ignore BlockBodyTypeMismatch
    end

    SHOWN_WIDTH = 72 #: Integer
    SHOWN_INPUT_WIDTH = 50 #: Integer

    # A Hash too long for a line shows the leaves that tell it from the
    # other values first, since a Hash with the same keys starts the same
    # way, then the rest of its top-level scalars that fit, or nil when
    # none fits. A part with no literal shows its class.
    #: (Hash[untyped, untyped], Array[[Array[untyped], untyped]]) -> String?
    def shown_hash(value, differing)
      leaf_text = ->(item) { Emitters::Support.literal?(item) ? Emitters::Support.ruby_literal(Emitters::Support.marked(item)) : Emitters::Support.article(Emitters::Support.class_literal(item)) }
      text = lambda do |entries|
        omitted = entries.count { |path, _| path.one? } < value.size
        "a Hash with #{Emitters::Support.entries_text(entries.map { |path, item| [path, leaf_text.(item)] })}#{", ..." if omitted}"
      end
      told = differing.map(&:first)
      scalars = Emitters::Support.hash_leaves(value).select { |path, _| path.one? && !told.include?(path) }
      entries = scalars.reduce(differing) { |kept, entry| text.(kept + [entry]).length <= SHOWN_WIDTH ? kept + [entry] : kept }
      return if entries.empty?

      line = text.(entries)
      line.length <= SHOWN_WIDTH ? line : "#{line[0, SHOWN_WIDTH - 3]}..."
    end

    # An Array, a Struct, or a Data too long for a line says its size or
    # its class, then the leaves that tell it from the other values of that
    # size or class, since those start the same way and a cut start would
    # read alike, then the rest of its leaves that fit, or nil when none
    # fits. Values of another size or class are told apart by the start.
    #: (untyped, Array[untyped]) -> String?
    def shown_composite(value, values)
      leaves = composite_leaves(value)
      return if leaves.empty?

      head = value.is_a?(Array) ? "an Array of #{value.length}" : Emitters::Support.article(Emitters::Support.class_literal(value))
      differs = ->(peer, path) { !peer.key?(path) || !peer[path].eql?(leaves[path]) }
      peers = values.reject { |other| other.eql?(value) }.select { |other| same_shape?(other, value) }.map { |other| composite_leaves(other) }
      paths = leaves.keys
      # The telling leaves come first, in their order in the value.
      text = lambda do |told, rest = []|
        entries = (paths.select { |path| told.include?(path) } + rest).map { |path| "#{Emitters::Support.path_text(path)}: #{leaf_text(leaves[path])}" }
        "#{head} with #{entries.join(", ")}#{", ..." if told.length + rest.length < paths.length}"
      end
      told = [] #: Array[Array[untyped]]
      until peers.empty?
        best = paths.each_with_index.max_by { |path, index| [peers.count { |peer| differs.(peer, path) }, -index] }.first # steep:ignore NoMethod
        break if peers.none? { |peer| differs.(peer, best) } || (told.any? && text.(told + [best]).length > SHOWN_WIDTH)

        told << best
        peers.reject! { |peer| differs.(peer, best) }
      end
      rest = [] #: Array[Array[untyped]]
      paths.each { |path| rest << path if !told.include?(path) && text.(told, rest + [path]).length <= SHOWN_WIDTH }
      return if told.empty? && rest.empty?

      line = text.(told, rest)
      line.length <= SHOWN_WIDTH ? line : "#{line[0, SHOWN_WIDTH - 3]}..."
    end

    #: (untyped, untyped) -> bool
    def same_shape?(other, value)
      return other.is_a?(Array) && other.length == value.length if value.is_a?(Array)

      other.instance_of?(value.class)
    end

    # path => leaf under an Array, a Hash, a Struct, or a Data, with a
    # member as a Symbol key, so a path reads as a reader writes it:
    # [0].kind.
    #: (untyped, ?Array[untyped], ?Hash[Array[untyped], untyped]) -> Hash[Array[untyped], untyped]
    def composite_leaves(value, path = [], out = {})
      children = case value
        when Array then value.each_with_index.map { |item, index| [index, item] }
        when Hash then value.map { |key, item| [key.is_a?(Symbol) ? Emitters::Support::SymbolKey.new(key.to_s) : key, item] }
        when Struct, Data then value.to_h.map { |key, item| [Emitters::Support::SymbolKey.new(key.to_s), item] }
        else []
      end #: Array[[untyped, untyped]]
      if children.empty?
        out[path] = value unless path.empty?
        return out
      end

      children.each { |step, item| composite_leaves(item, path + [step], out) }
      out
    end

    #: (untyped) -> String
    def leaf_text(item)
      return Emitters::Support.ruby_literal(Emitters::Support.marked(item)) if Emitters::Support.literal?(item)

      Emitters::Support.article(Emitters::Support.class_literal(item))
    end

    # An input from the inputs file too long for a line is named by its
    # place there, and by its note when it has one; --json and --verbose
    # keep the whole input.
    #: (Engine::Pin) -> String
    def shown_input(pin)
      text = pin.input.text
      return text unless text.length > SHOWN_INPUT_WIDTH && pin.listed_at

      pin.input.note ? "inputs[#{pin.listed_at}] (#{pin.input.note})" : "inputs[#{pin.listed_at}]"
    end

    # An input as the JSON report writes it: the call, and the note of the
    # inputs file, so an entry pasted back keeps its reason.
    #: (Input) -> Hash[String, untyped]
    def input_hash(input)
      input.note ? input.to_h.merge("note" => input.note) : input.to_h
    end

    #: (Array[String], Array[returned_row]) -> void
    def returned_brief(lines, groups)
      return if groups.empty?

      lines << "" << "RETURNED (coverage does not check a value; compare each with what the method should return)"
      groups.each { |shown, _, group| lines << "returns #{shown} for #{group.map { |pin| shown_input(pin) }.join(", ")}" }
    end

    #: (Array[String], Array[Engine::Finding]) -> void
    def exceptions_brief(lines, findings)
      return if findings.empty?

      lines << "" << "EXCEPTIONS"
      # A message often quotes its own input, so one raise grouped by
      # message would print once for each input that reached it.
      findings.group_by { |finding| [finding.class_name, finding.loc] }.each do |(name, loc), group|
        first = group.first
        by = group.one? ? first.input.text : "#{count(group.length, "input")}, such as #{first.input.text}"
        lines << "#{name}#{" at #{loc}" if loc} raised by #{by}: #{first.message}"
      end
    end

    # What each after read, once its call returned or raised, as
    # [source, shown, value, pins], grouped as RETURNED groups what the
    # calls returned. A call's value and its after are told apart, so a
    # raise that left the receiver changed reads as both.
    #: (Array[Engine::Pin]) -> Array[after_row]
    def after(pins)
      # Only an input with an after has what it observed.
      pins.select(&:observed).group_by { |pin| pin.input.after.source }.sort_by(&:first).flat_map do |source, group| # steep:ignore NoMethod
        returned(group.map { |pin| Emitters::Support.after_pin(pin) }, []).map { |shown, whole, read| [source, shown, whole, read] } # steep:ignore BlockBodyTypeMismatch
      end
    end

    # The inputs whose after read nothing, as [source, reason, pins].
    #: (Array[Engine::Pin]) -> Array[[String, String, Array[Engine::Pin]]]
    def after_unread(pins)
      unread = pins.select { |pin| pin.input.after && !pin.observed }
      unread.group_by { |pin| [pin.input.after.source, unread_reason(pin)] }.sort_by(&:first).map { |(source, reason), group| [source, reason, group] } # steep:ignore NoMethod
    end

    #: (Engine::Pin) -> String
    def unread_reason(pin)
      pin.error&.class_name == "Timeout::Error" ? "the call timed out" : "new or a setup call raised before the call"
    end

    #: (Array[String], Array[after_row], Array[[String, String, Array[Engine::Pin]]]) -> void
    def after_brief(lines, groups, unread)
      return if groups.empty? && unread.empty?

      lines << "" << "AFTER (what each after read once its call returned or raised; compare each with the state the call should leave)"
      groups.each { |source, shown, _, group| lines << "#{source} is #{shown} for #{group.map { |pin| shown_input(pin) }.join(", ")}" }
      unread.each { |source, reason, group| lines << "#{source} read nothing for #{group.map { |pin| shown_input(pin) }.join(", ")}: #{reason}" }
    end

    #: (Array[String], Array[Engine::Arm]) -> void
    def not_pinned_brief(lines, arms)
      return if arms.empty?

      lines << "" << "NOT PINNED (each input that took these arms returned a value that differed between two runs, so no emitted test checks them)"
      arms.group_by { |arm| arm.input.text }.each do |input, group| # steep:ignore NoMethod
        lines << "input: #{input}"
        group.each { |arm| lines << "#{arm.loc} #{WANTS.fetch(arm.sense, "takes the arm at `%s`") % arm.cond}" }
      end
    end

    # Each part of a returned value that an emitted test can check only by
    # its class, as "value[:at]" => [class name, inputs that returned it].
    #: (Array[Engine::Pin], Array[String]) -> Array[[String, String, Array[Input]]]
    def pinned_by_class(pins, pin_keys)
      by_class = lambda do |pin, keys, root|
        Emitters::Support.class_pins(Emitters::Support.pinned_value(pin.value, Emitters::Support.keys_for(pin, keys))).map { |path, name| [["#{root}#{path}", name], pin.input] }
      end
      parts = pins.reject { |pin| pin.error || pin.varying == :whole }.flat_map { |pin| by_class.(pin, pin_keys, "value") }
      # An after's value is pinned as a returned one is, so its parts with
      # no literal are checked by their class too.
      parts += pins.filter_map { |pin| Emitters::Support.after_pin(pin) }.reject { |pin| pin.varying == :whole }
                   .flat_map { |pin| by_class.(pin, [], pin.input.after.source) } # steep:ignore NoMethod
      parts.group_by(&:first).map do |(path, name), group|
        [path, name, group.map(&:last).uniq(&:canonical)]
      end
    end

    #: (Array[String], Array[Engine::Pin], Array[String]) -> void
    def pinned_by_class_brief(lines, pins, pin_keys)
      parts = pinned_by_class(pins, pin_keys)
      return if parts.empty?

      lines << "" << "PINNED BY CLASS (the emitted tests check only the class of these returned values, which have no Ruby literal; " \
                     "assert what matters in each by hand)"
      parts.each do |path, name, inputs|
        more = inputs.length - SHOWN_INPUTS
        lines << "#{path} is #{Emitters::Support.article(name)}: #{inputs.first(SHOWN_INPUTS).map(&:text).join(", ")}#{" and #{more} more" if more.positive?}"
      end
    end

    #: (Array[String], Array[Runner::Callee]) -> void
    def not_counted_brief(lines, callees)
      return if callees.empty?

      lines << "" << "NOT COUNTED (arms in other files; explore each as its own entry)"
      callees.each do |callee|
        lines << "#{callee.name} at #{callee.loc} (#{callee.arms.nil? ? "arms unknown" : count(callee.arms, "arm")})"
      end
    end

    #: (Array[String], Array[Target::Operator]) -> void
    def operators_brief(lines, operators)
      return if operators.empty?

      lines << "" << "OPERATORS (coverage does not see which side ran; vary each left side)"
      operators.each { |found| lines << "#{found.loc} #{found.op} in `#{found.text}`" }
    end

    #: (Array[String], Array[Target::Operator]) -> void
    def boundaries_brief(lines, boundaries)
      return if boundaries.empty?

      lines << "" << "BOUNDARIES (each comparison in the counted code, listed whether or not an input made both sides equal; coverage does not see which did)"
      boundaries.each { |found| lines << "#{found.loc} #{found.op} in `#{found.text}`" }
    end

    #: (Engine::Result, ?Array[String]) -> String
    def full_text(result, pin_keys = [])
      lines = header_lines(result)
      section(lines, "COVERED", result.covered) { |arm| covered_lines(arm) }
      section(lines, "FRONTIER", result.frontier) { |arm| [*frontier_lines(arm), "path: #{format_path(arm.path)}"] }
      section(lines, "RETURNED", returned(Array(result.pins), pin_keys)) { |shown, whole, group| ["returns: #{whole || shown}", *group.map { |pin| "input: #{pin.input.text}" }] }
      section(lines, "EXCEPTIONS", result.exceptions) { |finding| finding_lines(finding) }
      read = after(Array(result.pins)).map { |source, shown, whole, group| ["after: #{source}", "is: #{whole || shown}", group] } +
             after_unread(Array(result.pins)).map { |source, reason, group| ["after: #{source}", "read nothing: #{reason}", group] }
      unless read.empty?
        section(lines, "AFTER", read) { |source, outcome, group| [source, outcome, *group.map { |pin| "input: #{pin.input.text}" }] }
      end
      section(lines, "NOT COUNTED", Array(result.not_counted)) { |callee| callee_lines(callee) }
      section(lines, "OPERATORS", Array(result.operators)) { |found| operator_lines(found) }
      section(lines, "BOUNDARIES", Array(result.boundaries)) { |found| operator_lines(found) }
      "#{lines.join("\n")}\n"
    end

    #: (Engine::Result, ?pin_keys: Array[String]) -> String
    def json(result, pin_keys: [])
      body = {
        "version" => 1,
        "command" => result.command,
        "target" => result.target,
        "entry" => result.entry,
        "seed" => result.seed,
        "strategies" => result.strategies,
        "random" => result.random,
        "mutate_cap" => result.mutate_cap,
        "timeout" => result.timeout,
        "inputs_ran" => result.inputs_ran,
        "mutate_ran" => result.mutate_ran,
        "random_ran" => result.random_ran,
        "executions" => result.executions,
        "arms_covered" => result.covered.length,
        "arms_total" => result.covered.length + result.frontier.length,
        "covered" => result.covered.map { |arm| covered_hash(arm) },
        "arms_not_pinned" => result.covered.reject(&:pinned).map { |arm| covered_hash(arm) },
        "frontier" => result.frontier.map { |arm| frontier_hash(arm) },
        "returned" => returned(Array(result.pins), pin_keys).map { |shown, whole, group|
          {"returns" => shown, "value" => whole, "inputs" => group.map { |pin| input_hash(pin.input) }}.compact
        },
        "exceptions" => result.exceptions.map { |finding| finding_hash(finding) },
        "after" => after(Array(result.pins)).map { |source, shown, whole, group|
          {"after" => source, "is" => shown, "value" => whole, "inputs" => group.map { |pin| input_hash(pin.input) }}.compact
        } + after_unread(Array(result.pins)).map { |source, reason, group|
          {"after" => source, "read_nothing" => reason, "inputs" => group.map { |pin| input_hash(pin.input) }}
        },
        "not_counted" => Array(result.not_counted).map { |callee| callee_hash(callee) },
        "operators_not_counted" => Array(result.operators).map { |found| operator_hash(found) },
        "boundaries_not_counted" => Array(result.boundaries).map { |found| operator_hash(found) },
        "pinned_by_class" => pinned_by_class(Array(result.pins), pin_keys).map do |path, name, inputs|
          {"path" => path, "class" => name, "inputs" => inputs.map { |input| input_hash(input) }}
        end
      }
      "#{Canon.pretty(body)}\n"
    end

    #: (Engine::Result) -> String
    def markdown(result)
      "# branchout #{result.command}\n\n#{full_text(result)}"
    end

    #: (baselines_info, Array[[String, Engine::Result]]) -> String
    def baselines_text(info, rows)
      lines = [
        "branchout baselines",
        "target: #{info[:target]}",
        "entry: #{info[:entry]}",
        "seed: #{info[:seed]}",
        "random: #{info[:random]}",
        "mutate_cap: #{info[:mutate_cap]}",
        "timeout: #{format_timeout(info[:timeout])}",
        format("%-10s %11s %8s %6s %11s", "strategy", "executions", "covered", "total", "exceptions")
      ]
      rows.each do |name, result|
        total = result.covered.length + result.frontier.length
        lines << format(
          "%-10s %11d %8d %6d %11d",
          name, result.executions, result.covered.length, total, result.exceptions.length
        )
      end
      lines << ""
      rows.each do |name, result|
        ids = result.covered.map(&:id)
        lines << "#{name}_covered: #{ids.empty? ? "(none)" : ids.join(", ")}"
        classes = result.exceptions.map(&:class_name)
        lines << "#{name}_exceptions: #{classes.empty? ? "(none)" : classes.join(", ")}"
      end
      "#{lines.join("\n")}\n"
    end

    #: (baselines_info, Array[[String, Engine::Result]]) -> String
    def baselines_json(info, rows)
      body = {
        "version" => 1,
        "command" => "baselines",
        "target" => info[:target],
        "entry" => info[:entry],
        "seed" => info[:seed],
        "random" => info[:random],
        "mutate_cap" => info[:mutate_cap],
        "timeout" => info[:timeout],
        "rows" => rows.map { |name, result|
          {
            "strategy" => name,
            "executions" => result.executions,
            "covered" => result.covered.length,
            "total" => result.covered.length + result.frontier.length,
            "exceptions" => result.exceptions.length,
            "covered_ids" => result.covered.map(&:id),
            "exception_classes" => result.exceptions.map(&:class_name)
          }
        }
      }
      "#{Canon.pretty(body)}\n"
    end

    #: (baselines_info, Array[[String, Engine::Result]]) -> String
    def baselines_markdown(info, rows)
      "# branchout baselines\n\n#{baselines_text(info, rows)}"
    end

    # A setting of a strategy that did not run is left out, so it does not
    # read as active. The JSON report holds every setting.
    #: (Engine::Result) -> Array[String]
    def header_lines(result)
      ran = ->(strategy) { result.strategies.include?(strategy) }
      [
        "branchout #{result.command}",
        "target: #{result.target}",
        "entry: #{result.entry}",
        *("seed: #{result.seed}" if ran.("random")),
        "strategies: #{result.strategies.join(",")}",
        *("random: #{result.random}" if ran.("random")),
        *("mutate_cap: #{result.mutate_cap}" if ran.("mutate")),
        "timeout: #{format_timeout(result.timeout)}",
        *("inputs_ran: #{result.inputs_ran}" if ran.("inputs")),
        *("mutate_ran: #{result.mutate_ran}" if ran.("mutate")),
        *("random_ran: #{result.random_ran}" if ran.("random")),
        "executions: #{result.executions}",
        "arms_covered: #{result.covered.length}",
        "arms_total: #{result.covered.length + result.frontier.length}",
        "exceptions: #{result.exceptions.length}",
        "callees_not_counted: #{Array(result.not_counted).length}",
        "operators_not_counted: #{Array(result.operators).length}",
        "boundaries_not_counted: #{Array(result.boundaries).length}"
      ] #: Array[String]
    end

    #: (Array[String], String, Array[untyped]) { (untyped) -> Array[String] } -> void
    def section(lines, title, records)
      lines << ""
      lines << title
      if records.empty?
        lines << "(none)"
        return
      end
      records.each_with_index do |record, index|
        lines << "" if index.positive?
        lines.concat(yield(record))
      end
    end

    #: (Engine::Arm) -> Array[String]
    def covered_lines(arm)
      [
        "id: #{arm.id}",
        "loc: #{arm.loc}",
        "cond: #{arm.cond}",
        "sense: #{arm.sense}",
        "input: #{arm.input.text}", # steep:ignore NoMethod
        *("pinned: no, the input differed between two runs" unless arm.pinned)
      ] #: Array[String]
    end

    #: (Engine::Arm) -> Array[String]
    def frontier_lines(arm)
      [
        "id: #{arm.id}",
        "loc: #{arm.loc}",
        "cond: #{arm.cond}",
        "sense: #{arm.sense}",
        "parent: #{arm.parent}",
        "nearest: #{arm.nearest ? arm.nearest.text : "null"}"
      ]
    end

    #: (Engine::Finding) -> Array[String]
    def finding_lines(finding)
      [
        "class: #{finding.class_name}",
        "loc: #{finding.loc || "null"}",
        "input: #{finding.input.text}",
        "message: #{finding.message}"
      ]
    end

    #: (Runner::Callee) -> Array[String]
    def callee_lines(callee)
      ["callee: #{callee.name}", "loc: #{callee.loc}", "arms: #{callee.arms.nil? ? "unknown" : callee.arms}"]
    end

    #: (Target::Operator) -> Array[String]
    def operator_lines(found)
      ["loc: #{found.loc}", "op: #{found.op}", "text: #{found.text}"]
    end

    #: (Target::Operator) -> Hash[String, untyped]
    def operator_hash(found)
      {"loc" => found.loc, "line" => found.line, "column" => found.column, "op" => found.op, "text" => found.text}
    end

    #: (Runner::Callee) -> Hash[String, untyped]
    def callee_hash(callee)
      {"callee" => callee.name, "loc" => callee.loc, "arms" => callee.arms}
    end

    #: (Array[String]?) -> String
    def format_path(path)
      return "null" if path.nil?
      return "(none)" if path.empty?

      path.join(", ")
    end

    #: (Engine::Arm) -> Hash[String, untyped]
    def covered_hash(arm)
      {
        "id" => arm.id,
        "loc" => arm.loc,
        "line" => arm.line,
        "column" => arm.column,
        "cond" => arm.cond,
        "sense" => arm.sense,
        "input" => input_hash(arm.input) # steep:ignore ArgumentTypeMismatch
      }
    end

    #: (Engine::Arm) -> Hash[String, untyped]
    def frontier_hash(arm)
      {
        "id" => arm.id,
        "loc" => arm.loc,
        "line" => arm.line,
        "column" => arm.column,
        "cond" => arm.cond,
        "sense" => arm.sense,
        "parent" => arm.parent,
        "nearest" => (input_hash(arm.nearest) if arm.nearest),
        "path" => arm.path
      }
    end

    #: (Engine::Finding) -> Hash[String, untyped]
    def finding_hash(finding)
      {
        "class" => finding.class_name,
        "loc" => finding.loc,
        "input" => input_hash(finding.input),
        "message" => finding.message
      }
    end

    #: (Integer | Float | nil) -> String
    def format_timeout(value)
      return "none" if value.nil?

      return value.to_i.to_s if value == value.to_i

      Canon.format_float(value.to_f)
    end
  end
end
