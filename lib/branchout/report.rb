# frozen_string_literal: true

module Branchout
  module Report
    module_function

    def text(result)
      lines = header_lines(result)
      section(lines, "COVERED", result.covered) { |arm| covered_lines(arm) }
      section(lines, "FRONTIER", result.frontier) { |arm| frontier_lines(arm) }
      section(lines, "EXCEPTIONS", result.exceptions) { |finding| finding_lines(finding) }
      section(lines, "NOT COUNTED", Array(result.not_counted)) { |callee| callee_lines(callee) }
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
        "not_counted" => Array(result.not_counted).map { |callee| callee_hash(callee) }
      }
      "#{Canon.pretty(body)}\n"
    end

    def markdown(result)
      "# branchout #{result.command}\n\n#{text(result)}"
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
        "callees_not_counted: #{Array(result.not_counted).length}"
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
        "nearest: #{arm.nearest ? arm.nearest.text : "null"}",
        "path: #{format_path(arm.path)}"
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
      return value.to_i.to_s if value == value.to_i

      Canon.format_float(value.to_f)
    end
  end
end
