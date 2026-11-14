# frozen_string_literal: true

module Branchout
  class Engine
    STRATEGY_ORDER = %w[inputs mutate random].freeze

    Result = Struct.new(
      :command, :target, :entry, :seed, :strategies, :random, :mutate_cap, :timeout,
      :inputs_ran, :mutate_ran, :random_ran, :executions,
      :covered, :frontier, :exceptions, :pins, :requires, :load_paths, :target_required, :private_calls, :const_expression, :repeated_inputs, :not_counted,
      :operators, :memos, :defined_memos, :boundaries,
      :test_class, :spec_type,
      keyword_init: true
    )

    # +pinned+ is false for a covered arm whose every input differed as a
    # whole between two runs, so no emitted test checks it.
    Arm = Struct.new(
      :id, :loc, :line, :column, :cond, :sense, :input, :parent, :nearest, :path,
      :covered, :pinned,
      keyword_init: true
    )

    # +covers+ lists the arms the input took, in source order.
    # +thawed+ marks an input that ran with unfrozen Strings (Runner::Execution).
    # +varying+ is Runner::Execution's: what differed between two runs.
    # +listed_at+ is the input's index in the inputs file, or nil for an
    # input branchout made.
    # +observed+ is the Runner::Observation of what the input's after read,
    # or nil when the input has no after or its call timed out.
    Pin = Struct.new(:input, :value, :error, :covers, :thawed, :varying, :listed_at, :observed, keyword_init: true)
    Cover = Struct.new(:line, :column, :text, keyword_init: true)
    Finding = Struct.new(:class_name, :message, :loc, :input, :stable_message, keyword_init: true)

    def self.explore(target:, entry:, user_inputs: [], type_overrides: nil, seed: 0, strategies: STRATEGY_ORDER,
                     random: 16, mutate_cap: 256, timeout: 1, command: "explore", requires: [], load_paths: [], host: nil, after: nil)
      new(
        target: target, entry: entry, user_inputs: user_inputs, type_overrides: type_overrides,
        seed: seed, strategies: strategies, random: random, mutate_cap: mutate_cap,
        timeout: timeout, command: command, requires: requires, load_paths: load_paths, host: host, after: after
      ).explore
    end

    # +after+ is the inputs file's own after, the Code that reads what each
    # call left. The listed inputs have it already; the inputs that mutate
    # and random make get it here, so every call of the run reads the same.
    def initialize(target:, entry:, user_inputs:, type_overrides:, seed:, strategies:, random:, mutate_cap:, timeout:, command:,
                   requires:, load_paths:, host:, after: nil)
      @host = host
      @after = after
      @path = target
      @load_paths = load_paths.map { |dir| File.expand_path(dir) }
      @requires = requires.map { |name| required_file(name) or raise Error, require_not_found(name) }
      @entry = entry
      @user_inputs = user_inputs
      @type_overrides = type_overrides
      @seed = seed
      @strategies = STRATEGY_ORDER.select { |name| strategies.include?(name) }
      @random = random
      @mutate_cap = mutate_cap
      @timeout = timeout
      @command = command
    end

    def explore
      target = Target.parse(@path, @entry, type_overrides: @type_overrides)
      user = @strategies.include?("inputs") ? @user_inputs : []
      mutated = @strategies.include?("mutate") ? Mutator.new(target, cap: @mutate_cap).inputs : []
      randoms = @strategies.include?("random") ? Sampler.new(target, seed: @seed, count: @random).inputs : []
      mutated, randoms = [mutated, randoms].map { |list| list.map { |input| input.with(after: @after) } } if @after

      counts = {inputs: 0, mutate: 0, random: 0}
      seen = {}
      plan = []
      enqueue = lambda do |list, origin|
        list.each do |input|
          key = input.canonical
          next if seen[key]

          seen[key] = true
          plan << [input, origin]
          counts[origin] += 1
        end
      end
      enqueue.call(user, :inputs)
      enqueue.call(mutated, :mutate)
      enqueue.call(randoms, :random)

      runner = Runner.new(target, timeout: @timeout, requires: @requires, load_paths: @load_paths, host: @host)
      executions = plan.map do |input, origin|
        execution = runner.execute(input)
        execution.origin = origin
        execution
      end
      build_result(target, runner, executions, counts, user.length - counts[:inputs])
    end

    private

    # A require that names no file under the working directory is a
    # feature, as Ruby's own -r reads it: found on an -I directory, then on
    # the load path. Nil when it is found nowhere.
    def required_file(name)
      path = File.expand_path(name)
      return path if File.file?(path) || File.file?("#{path}.rb")

      feature = name.end_with?(".rb") ? name : "#{name}.rb"
      found = @load_paths.map { |dir| File.join(dir, feature) }.find { |file| File.file?(file) }
      found || $LOAD_PATH.resolve_feature_path(name)&.last
    end

    # In the words of the caller: Branchout.explore, the one caller that
    # passes a host, takes requires: and no -I.
    def require_not_found(name)
      if @host
        "requires: #{name.inspect} names no file under the working directory or on the load path"
      else
        "--require #{name} names no file under the working directory, an -I directory, or the load path"
      end
    end

    def build_result(target, runner, executions, counts, repeated_inputs)
      # Coverage lists every branch of the file, taken or not, so the table
      # from loading holds every arm an execution can report.
      arms = runner.template[:branches].flat_map do |branch_key, arm_counts|
        arm_counts.keys.map { |arm_key| make_arm(target, branch_key, arm_key, executions) }
      end
      covered = arms.select(&:covered).sort_by(&:id)
      frontier = arms.reject(&:covered).sort_by(&:id)
      findings = collect_findings(executions)
      pins = collect_pins(target, executions, covered, findings)

      Result.new(
        command: @command,
        target: target.display_path,
        entry: target.entry,
        seed: @seed,
        strategies: @strategies,
        random: @random,
        mutate_cap: @mutate_cap,
        timeout: @timeout,
        inputs_ran: counts[:inputs],
        mutate_ran: counts[:mutate],
        random_ran: counts[:random],
        executions: executions.length,
        covered: covered,
        frontier: frontier,
        exceptions: findings,
        pins: pins,
        requires: @requires,
        load_paths: @load_paths,
        target_required: runner.target_required,
        private_calls: runner.private_calls,
        const_expression: runner.const_expression,
        repeated_inputs: repeated_inputs,
        not_counted: runner.not_counted,
        operators: target.operators,
        memos: target.memos,
        defined_memos: target.defined_memos,
        boundaries: target.boundaries,
        test_class: @host&.test_class,
        spec_type: @host&.spec_type
      )
    end

    def make_arm(target, branch_key, arm_key, executions)
      id = format_id(branch_key, arm_key)
      line = arm_key[2]
      column = arm_key[3]
      takers = executions.select { |execution| count_of(execution, branch_key, arm_key).positive? }
      if takers.empty?
        nearest = best_execution(executions.select { |execution| parent_reached?(execution, branch_key) })
        Arm.new(
          id: id,
          loc: "#{target.display_path}:#{line}:#{column}",
          line: line,
          column: column,
          cond: target.condition_text(branch_key[0], branch_key[2], branch_key[3], arm_key[0], line, column),
          sense: sense_for(branch_key[0], arm_key[0]),
          parent: nearest ? "reached" : "not-reached",
          nearest: nearest&.input,
          path: nearest ? path_ids(nearest) : nil,
          covered: false
        )
      else
        pinnable = takers.reject { |execution| execution.varying == :whole }
        witness = best_execution(pinnable.empty? ? takers : pinnable)
        Arm.new(
          id: id,
          loc: "#{target.display_path}:#{line}:#{column}",
          line: line,
          column: column,
          cond: target.condition_text(branch_key[0], branch_key[2], branch_key[3], arm_key[0], line, column),
          sense: sense_for(branch_key[0], arm_key[0]),
          input: witness.input,
          parent: "reached",
          path: path_ids(witness),
          covered: true,
          pinned: !pinnable.empty?
        )
      end
    end

    def collect_findings(executions)
      chosen = {}
      executions.each do |execution|
        info = execution.error
        next unless info

        key = [info.class_name, info.message, info.loc.to_s, execution.input.canonical]
        chosen[key] ||= execution
      end
      chosen.values.sort_by { |execution|
        info = execution.error
        [info.class_name, info.loc.to_s, info.message, execution.input.canonical]
      }.map { |execution|
        info = execution.error
        Finding.new(
          class_name: info.class_name,
          message: info.message,
          loc: info.loc,
          input: execution.input,
          stable_message: info.stable_message
        )
      }
    end

    def collect_pins(target, executions, covered, findings)
      by_input = executions.to_h { |execution| [execution.input.canonical, execution] }
      keys = executions.select { |execution| execution.origin == :inputs }.map { |execution| execution.input.canonical } |
             covered.map { |arm| arm.input.canonical } | findings.map { |finding| finding.input.canonical }
      listed = {}
      @user_inputs.each_with_index { |input, at| listed[input.canonical] ||= at }
      keys.sort.map do |key|
        execution = by_input[key]
        Pin.new(
          listed_at: (listed[key] if execution.origin == :inputs),
          input: execution.input,
          value: execution.value,
          error: execution.error,
          covers: covers_of(target, execution),
          thawed: execution.thawed,
          varying: execution.varying,
          observed: execution.observed
        )
      end
    end

    def covers_of(target, execution)
      covers = execution.branches.flat_map do |branch_key, arms|
        arms.filter_map do |arm_key, count|
          next unless count.to_i.positive?

          line, text = target.covered_arm(branch_key[0], branch_key[2], branch_key[3], arm_key[0], arm_key[2], arm_key[3])
          Cover.new(line: line, column: branch_key[3], text: text)
        end
      end
      covers.sort_by { |cover| [cover.line, cover.column, cover.text] }
    end

    def best_execution(executions)
      executions.min_by { |execution| [path_ids(execution).length, execution.input.weight, execution.input.canonical] }
    end

    def parent_reached?(execution, branch_key)
      return true if execution.branches[branch_key].values.any? { |count| count.to_i.positive? }
      return false unless branch_key[0] == :while || branch_key[0] == :until

      line = branch_key[2]
      execution.lines[line - 1].to_i.positive?
    end

    def count_of(execution, branch_key, arm_key)
      execution.branches[branch_key]&.[](arm_key).to_i
    end

    def path_ids(execution)
      execution.path_ids ||= path_with_counts(execution)
    end

    def path_with_counts(execution)
      ids = []
      execution.branches.each do |branch_key, arms|
        arms.each do |arm_key, count|
          next unless count.to_i.positive?

          id = format_id(branch_key, arm_key)
          id = "#{id}*#{count}" if count.to_i > 1
          ids << id
        end
      end
      ids.sort
    end

    def format_id(branch_key, arm_key)
      "#{branch_key[0]}@#{branch_key[2]}:#{branch_key[3]}/#{arm_key[0]}@#{arm_key[2]}:#{arm_key[3]}"
    end

    def sense_for(branch_type, arm_type)
      case [branch_type, arm_type]
      when [:if, :then], [:unless, :else] then "cond-true"
      when [:if, :else], [:unless, :then] then "cond-false"
      when [:while, :body], [:until, :body] then "body-entered"
      when [:case, :when], [:case, :in] then "arm-matched"
      when [:case, :else] then "arm-else"
      when [:"&.", :then] then "receiver-present"
      when [:"&.", :else] then "receiver-nil"
      else "taken"
      end
    end
  end
end
