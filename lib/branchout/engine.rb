# frozen_string_literal: true

module Branchout
  class Engine
    STRATEGY_ORDER = %w[inputs mutate random].freeze

    Result = Struct.new(
      :command, :target, :entry, :seed, :strategies, :random, :mutate_cap, :timeout,
      :inputs_ran, :mutate_ran, :random_ran, :executions,
      :covered, :frontier, :exceptions, :pins, :requires, :private_calls, :repeated_inputs,
      keyword_init: true
    )

    Arm = Struct.new(
      :id, :loc, :line, :column, :cond, :sense, :input, :parent, :nearest, :path,
      :covered, :value, :error,
      keyword_init: true
    )

    Pin = Struct.new(:input, :value, :error, :arm_ids, keyword_init: true)
    Finding = Struct.new(:class_name, :message, :loc, :input, :stable_message, keyword_init: true)

    def self.explore(target:, entry:, user_inputs: [], type_overrides: nil, seed: 0, strategies: STRATEGY_ORDER,
                     random: 16, mutate_cap: 256, timeout: 1, command: "explore", requires: [])
      new(
        target: target, entry: entry, user_inputs: user_inputs, type_overrides: type_overrides,
        seed: seed, strategies: strategies, random: random, mutate_cap: mutate_cap,
        timeout: timeout, command: command, requires: requires
      ).explore
    end

    def initialize(target:, entry:, user_inputs:, type_overrides:, seed:, strategies:, random:, mutate_cap:, timeout:, command:,
                   requires:)
      @path = target
      @requires = requires.map { |path| File.expand_path(path) }
      @entry = entry
      @user_inputs = user_inputs
      @type_overrides = type_overrides
      @seed = seed
      @strategies = STRATEGY_ORDER.select { |name| strategies.include?(name) }
      raise Error, "strategy list is empty" if @strategies.empty?

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

      runner = Runner.new(target, timeout: @timeout, requires: @requires)
      executions = plan.map do |input, origin|
        execution = runner.execute(input)
        execution.origin = origin
        execution
      end
      build_result(target, runner, executions, counts, user.length - counts[:inputs])
    end

    private

    def build_result(target, runner, executions, counts, repeated_inputs)
      catalog = {}
      runner.template[:branches].each do |branch_key, arms|
        catalog[branch_key] ||= []
        arms.each_key { |arm_key| catalog[branch_key] << arm_key unless catalog[branch_key].include?(arm_key) }
      end
      executions.each do |execution|
        execution.branches.each do |branch_key, arms|
          catalog[branch_key] ||= []
          arms.each_key { |arm_key| catalog[branch_key] << arm_key unless catalog[branch_key].include?(arm_key) }
        end
      end

      arms = catalog.flat_map do |branch_key, arm_keys|
        arm_keys.map { |arm_key| make_arm(target, branch_key, arm_key, executions) }
      end
      covered = arms.select(&:covered).sort_by(&:id)
      frontier = arms.reject(&:covered).sort_by(&:id)
      findings = collect_findings(executions)
      pins = collect_pins(executions, covered, findings)

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
        private_calls: runner.private_calls,
        repeated_inputs: repeated_inputs
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
          input: nil,
          parent: nearest ? "reached" : "not-reached",
          nearest: nearest&.input,
          path: nearest ? path_ids(nearest) : nil,
          covered: false,
          value: nil,
          error: nil
        )
      else
        witness = best_execution(takers)
        Arm.new(
          id: id,
          loc: "#{target.display_path}:#{line}:#{column}",
          line: line,
          column: column,
          cond: target.condition_text(branch_key[0], branch_key[2], branch_key[3], arm_key[0], line, column),
          sense: sense_for(branch_key[0], arm_key[0]),
          input: witness.input,
          parent: "reached",
          nearest: nil,
          path: path_ids(witness),
          covered: true,
          value: witness.value,
          error: witness.error
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

    def collect_pins(executions, covered, findings)
      by_input = {}
      keys = {}
      executions.each do |execution|
        by_input[execution.input.canonical] = execution
        keys[execution.input.canonical] = true if execution.origin == :inputs
      end
      covered.each do |arm|
        keys[arm.input.canonical] = true
      end
      findings.each do |finding|
        keys[finding.input.canonical] = true
      end
      keys.keys.sort.map do |key|
        execution = by_input[key]
        Pin.new(
          input: execution.input,
          value: execution.value,
          error: execution.error,
          arm_ids: covered_ids(execution)
        )
      end
    end

    def covered_ids(execution)
      ids = []
      execution.branches.each do |branch_key, arms|
        arms.each do |arm_key, count|
          ids << format_id(branch_key, arm_key) if count.to_i.positive?
        end
      end
      ids.sort
    end

    def best_execution(executions)
      executions.min_by { |execution| [path_ids(execution).length, execution.input.weight, execution.input.canonical] }
    end

    def parent_reached?(execution, branch_key)
      arms = execution.branches[branch_key]
      return false unless arms
      return true if arms.values.any? { |count| count.to_i.positive? }
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
