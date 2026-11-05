# frozen_string_literal: true

module Branchout
  module Report
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
    }.freeze
    SHOWN_INPUTS = 3

    # The default leads with what to act on: the counts, then each arm an
    # input reached but did not take. The run settings and the covered arms
    # are in +verbose+ and in the JSON.
    def text(result, tests: nil, verbose: false, verbose_flag: "--verbose")
      return full_text(result) if verbose

      total = result.covered.length + result.frontier.length
      raised = result.exceptions.length
      lines = [
        "branchout #{result.command} #{result.target} #{result.entry}",
        "covered: #{result.covered.length} of #{total} arms by #{count(result.executions, "input")}",
        "raised: #{raised.zero? ? "none" : count(raised, "input")}"
      ]
      lines << "tests: #{Target.display_path(tests)}" if tests
      frontier_brief(lines, result.frontier)
      exceptions_brief(lines, result.exceptions)
      not_counted_brief(lines, Array(result.not_counted))
      operators_brief(lines, Array(result.operators))
      lines << "" << "Pass #{verbose_flag} for every covered arm and the run settings."
      "#{lines.join("\n")}\n"
    end

    def frontier_brief(lines, frontier)
      reached, waiting = frontier.partition { |arm| arm.parent == "reached" }
      lines << "" << (reached.any? ? "FRONTIER (add an input like the nearest above each arm, changed as the arm says)" : "FRONTIER")
      lines << "(none)" if frontier.empty?
      # Consecutive arms share one nearest line, so a first run's single
      # input is printed once, not once for each arm it reached.
      shown = nil
      reached.sort_by { |arm| [arm.line, arm.column, arm.id] }.each do |arm|
        nearest = arm.nearest ? arm.nearest.text : "null"
        lines << "nearest: #{nearest}" unless nearest == shown
        shown = nearest
        lines << "#{arm.loc} #{WANTS.fetch(arm.sense, "takes the arm at `%s`") % arm.cond}"
      end
      return if waiting.empty?

      lines << "" if reached.any?
      lines << (reached.any? ? "not reached yet; take the arms above first:" : "no input reached these decisions:")
      # An id is "kind@line:column/arm@line:column"; its first half names the decision.
      decisions = waiting.group_by { |arm| arm.id.split("/").first.match(/\A(.+)@(\d+):(\d+)\z/).captures }
      decisions.sort_by { |(_, line, column), _| [line.to_i, column.to_i] }.each do |(kind, line, _), arms|
        file = arms.first.loc.sub(/:\d+:\d+\z/, "")
        conds = arms.map(&:cond).uniq
        lines << "#{file}:#{line} #{conds.one? ? conds.first : kind} (#{count(arms.length, "arm")})"
      end
    end

    def count(number, noun)
      "#{number} #{noun}#{"s" unless number == 1}"
    end

    def exceptions_brief(lines, findings)
      return if findings.empty?

      lines << "" << "EXCEPTIONS"
      findings.group_by { |finding| [finding.class_name, finding.loc, finding.message] }.each do |(name, loc, message), group|
        lines << "#{name}#{" at #{loc}" if loc}: #{message}"
        shown = group.first(SHOWN_INPUTS).map { |finding| finding.input.text }.join(", ")
        more = group.length - SHOWN_INPUTS
        lines << "  inputs: #{shown}#{" and #{more} more" if more.positive?}"
      end
    end

    def not_counted_brief(lines, callees)
      return if callees.empty?

      lines << "" << "NOT COUNTED (arms in other files; explore each as its own entry)"
      callees.each do |callee|
        lines << "#{callee.name} at #{callee.loc} (#{callee.arms.nil? ? "arms unknown" : count(callee.arms, "arm")})"
      end
    end

    def operators_brief(lines, operators)
      return if operators.empty?

      lines << "" << "OPERATORS (coverage does not see which side ran; vary each left side)"
      operators.each { |found| lines << "#{found.loc} #{found.op} in `#{found.text}`" }
    end

    def full_text(result)
      lines = header_lines(result)
      section(lines, "COVERED", result.covered) { |arm| covered_lines(arm) }
      section(lines, "FRONTIER", result.frontier) { |arm| [*frontier_lines(arm), "path: #{format_path(arm.path)}"] }
      section(lines, "EXCEPTIONS", result.exceptions) { |finding| finding_lines(finding) }
      section(lines, "NOT COUNTED", Array(result.not_counted)) { |callee| callee_lines(callee) }
      section(lines, "OPERATORS", Array(result.operators)) { |found| operator_lines(found) }
      "#{lines.join("\n")}\n"
    end

    def json(result)
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
        "frontier" => result.frontier.map { |arm| frontier_hash(arm) },
        "exceptions" => result.exceptions.map { |finding| finding_hash(finding) },
        "not_counted" => Array(result.not_counted).map { |callee| callee_hash(callee) },
        "operators_not_counted" => Array(result.operators).map { |found| operator_hash(found) }
      }
      "#{Canon.pretty(body)}\n"
    end

    def markdown(result)
      "# branchout #{result.command}\n\n#{full_text(result)}"
    end

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

    def baselines_markdown(info, rows)
      "# branchout baselines\n\n#{baselines_text(info, rows)}"
    end

    def header_lines(result)
      [
        "branchout #{result.command}",
        "target: #{result.target}",
        "entry: #{result.entry}",
        "seed: #{result.seed}",
        "strategies: #{result.strategies.join(",")}",
        "random: #{result.random}",
        "mutate_cap: #{result.mutate_cap}",
        "timeout: #{format_timeout(result.timeout)}",
        "inputs_ran: #{result.inputs_ran}",
        "mutate_ran: #{result.mutate_ran}",
        "random_ran: #{result.random_ran}",
        "executions: #{result.executions}",
        "arms_covered: #{result.covered.length}",
        "arms_total: #{result.covered.length + result.frontier.length}",
        "exceptions: #{result.exceptions.length}",
        "callees_not_counted: #{Array(result.not_counted).length}",
        "operators_not_counted: #{Array(result.operators).length}"
      ]
    end

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

    def covered_lines(arm)
      [
        "id: #{arm.id}",
        "loc: #{arm.loc}",
        "cond: #{arm.cond}",
        "sense: #{arm.sense}",
        "input: #{arm.input.text}"
      ]
    end

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

    def finding_lines(finding)
      [
        "class: #{finding.class_name}",
        "loc: #{finding.loc || "null"}",
        "input: #{finding.input.text}",
        "message: #{finding.message}"
      ]
    end

    def callee_lines(callee)
      ["callee: #{callee.name}", "loc: #{callee.loc}", "arms: #{callee.arms.nil? ? "unknown" : callee.arms}"]
    end

    def operator_lines(found)
      ["loc: #{found.loc}", "op: #{found.op}", "text: #{found.text}"]
    end

    def operator_hash(found)
      {"loc" => found.loc, "line" => found.line, "column" => found.column, "op" => found.op, "text" => found.text}
    end

    def callee_hash(callee)
      {"callee" => callee.name, "loc" => callee.loc, "arms" => callee.arms}
    end

    def format_path(path)
      return "null" if path.nil?
      return "(none)" if path.empty?

      path.join(", ")
    end

    def covered_hash(arm)
      {
        "id" => arm.id,
        "loc" => arm.loc,
        "line" => arm.line,
        "column" => arm.column,
        "cond" => arm.cond,
        "sense" => arm.sense,
        "input" => arm.input.to_h
      }
    end

    def frontier_hash(arm)
      {
        "id" => arm.id,
        "loc" => arm.loc,
        "line" => arm.line,
        "column" => arm.column,
        "cond" => arm.cond,
        "sense" => arm.sense,
        "parent" => arm.parent,
        "nearest" => arm.nearest&.to_h,
        "path" => arm.path
      }
    end

    def finding_hash(finding)
      {
        "class" => finding.class_name,
        "loc" => finding.loc,
        "input" => finding.input.to_h,
        "message" => finding.message
      }
    end

    def format_timeout(value)
      return "none" if value.nil?

      return value.to_i.to_s if value == value.to_i

      Canon.format_float(value.to_f)
    end
  end
end
