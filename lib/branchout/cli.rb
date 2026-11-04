# frozen_string_literal: true

require "fileutils"

module Branchout
  module CLI
    HELP = <<~TEXT
      branchout #{VERSION}

      Usage:
        branchout explore TARGET ENTRY [options]
        branchout baselines TARGET ENTRY [options]

      ENTRY is Const.method or Const#method. --entry ENTRY is accepted too.

      The tool does not call an LLM. It executes the inputs you pass, plus
      optional literal mutation and seeded random samples, and prints the
      branch arms that are still uncovered.

      Options:
        --inputs PATH       JSON file of candidate inputs
        --require PATH      load PATH before TARGET (repeatable)
        -I DIR              put DIR on the load path (repeatable)
        --seed N            RNG seed (default 0)
        --random N          random samples (default 16)
        --mutate-cap N      literal-mutation budget (default 256)
        --strategy LIST     comma list: inputs,mutate,random (default all)
        --timeout SEC       per-input timeout (default 1)
        --json              print JSON on stdout instead of text
        --json-out PATH     write JSON to a file
        --md-out PATH       write the text report as Markdown
        --emit-tests PATH   write characterization tests (explore only)
        --format NAME       minitest or rspec (default minitest; _spec.rb infers rspec)
        --pin-keys LIST     comma list of keys: a returned Hash pins only these keys
        --require-by-name   emitted tests require the --require files and the target
                            through the load path, named from the first -I directory or
                            --require file's directory that holds each (with neither, the
                            nearest lib directory above the target); a file none holds is
                            required by path, and the test and stderr say so; on by
                            default for a test under a .jitcatch directory
        --help
        --version
    TEXT

    module_function

    def start(argv)
      run(argv)
    rescue Error => e
      $stderr.puts "branchout: #{e.message}"
      1
    end

    def run(argv)
      args = argv.map(&:dup)
      if args.empty? || args == ["--help"] || args == ["-h"]
        puts HELP
        return 0
      end
      if args == ["--version"] || args == ["-v"]
        puts "branchout #{VERSION}"
        return 0
      end

      command = args.shift
      raise Error, "unknown command #{command.inspect}" unless %w[explore baselines].include?(command)

      opts = {
        seed: 0,
        random: 16,
        mutate_cap: 256,
        timeout: 1,
        strategies: Engine::STRATEGY_ORDER.dup,
        json: false,
        inputs: nil,
        entry: nil,
        json_out: nil,
        md_out: nil,
        emit_tests: nil,
        format: nil,
        require_by_name: false,
        pin_keys: [],
        requires: [],
        load_paths: []
      }
      positionals = []
      until args.empty?
        arg = args.shift
        case arg
        when "--inputs" then opts[:inputs] = take(args, arg)
        when "--require" then opts[:requires] << take(args, arg)
        when "-I" then opts[:load_paths] << take(args, arg)
        when /\A-I(.+)/ then opts[:load_paths] << Regexp.last_match(1)
        when "--seed" then opts[:seed] = parse_int(take(args, arg), "seed")
        when "--random" then opts[:random] = parse_int(take(args, arg), "random")
        when "--mutate-cap" then opts[:mutate_cap] = parse_int(take(args, arg), "mutate-cap")
        when "--timeout" then opts[:timeout] = parse_timeout(take(args, arg))
        when "--strategy" then opts[:strategies] = parse_strategies(take(args, arg))
        when "--entry" then opts[:entry] = take(args, arg)
        when "--json" then opts[:json] = true
        when "--json-out" then opts[:json_out] = take(args, arg)
        when "--md-out" then opts[:md_out] = take(args, arg)
        when "--emit-tests" then opts[:emit_tests] = take(args, arg)
        when "--format" then opts[:format] = take(args, arg)
        when "--require-by-name" then opts[:require_by_name] = true
        when "--pin-keys" then opts[:pin_keys] = parse_keys(take(args, arg))
        when "--help", "-h"
          puts HELP
          return 0
        else
          raise Error, "unknown option #{arg}" if arg.start_with?("-")

          positionals << arg
        end
      end

      target = positionals.shift
      entry = opts[:entry] || positionals.shift
      raise Error, "missing TARGET" unless target
      raise Error, "missing ENTRY" unless entry
      raise Error, "unexpected arguments: #{positionals.join(" ")}" unless positionals.empty?
      raise Error, "seed must be >= 0" if opts[:seed].negative?
      raise Error, "random count must be >= 0" if opts[:random].negative?
      raise Error, "mutate-cap must be >= 0" if opts[:mutate_cap].negative?
      if opts[:emit_tests] && command != "explore"
        raise Error, "--emit-tests is only valid with explore"
      end
      if opts[:require_by_name]
        raise Error, "--require-by-name requires --emit-tests" unless opts[:emit_tests]
      end
      raise Error, "--pin-keys requires --emit-tests" if !opts[:pin_keys].empty? && !opts[:emit_tests]
      if opts[:format] && !opts[:emit_tests]
        raise Error, "--format requires --emit-tests"
      end
      if opts[:emit_tests]
        opts[:format] = Emitters.resolve(opts[:format], opts[:emit_tests])
        # jitcatch copies a test under .jitcatch/ to the root of each
        # checkout, and its rerun line loads the test where it was written.
        # A require_relative names a different file from each place.
        opts[:require_by_name] ||= File.expand_path(opts[:emit_tests]).split("/").include?(".jitcatch")
      end

      user_inputs = []
      type_overrides = nil
      if opts[:inputs]
        user_inputs, type_overrides = InputFile.load(opts[:inputs])
      end

      case command
      when "explore"
        result = Engine.explore(
          target: target,
          entry: entry,
          user_inputs: user_inputs,
          type_overrides: type_overrides,
          seed: opts[:seed],
          strategies: opts[:strategies],
          random: opts[:random],
          mutate_cap: opts[:mutate_cap],
          timeout: opts[:timeout],
          requires: opts[:requires],
          load_paths: opts[:load_paths]
        )
        stdout = opts[:json] ? Report.json(result) : Report.text(result)
        $stdout.write(stdout)
        if result.repeated_inputs.positive?
          $stderr.puts "branchout: #{result.repeated_inputs} of #{user_inputs.length} inputs repeat an earlier input, " \
                       "so they did not run again."
        end
        if result.covered.empty? && result.frontier.empty?
          $stderr.puts "branchout: #{entry} and the methods it calls in #{result.target} have no branches. " \
                       "Only a bare call, a self. call, and a call on new are followed; target the method that branches. " \
                       "--emit-tests still pins the return value or error of each input."
        end
        write_optional(opts[:json_out], Report.json(result))
        write_optional(opts[:md_out], Report.markdown(result))
        if opts[:emit_tests]
          parsed = Target.parse(target, entry, type_overrides: type_overrides)
          format = Emitters.resolve(opts[:format], opts[:emit_tests])
          Emitters.write(format, result, parsed, opts[:emit_tests], require_by_name: opts[:require_by_name],
                                                                     pin_keys: opts[:pin_keys])
          warn_unnamed(result, target) if opts[:require_by_name]
        end
      when "baselines"
        info = {
          target: Target.display_path(File.expand_path(target)),
          entry: entry,
          seed: opts[:seed],
          random: opts[:random],
          mutate_cap: opts[:mutate_cap],
          timeout: opts[:timeout]
        }
        rows = [
          ["random", run_strategy(target, entry, user_inputs, type_overrides, opts, ["random"])],
          ["mutate", run_strategy(target, entry, user_inputs, type_overrides, opts, ["mutate"])],
          ["agent", run_strategy(target, entry, user_inputs, type_overrides, opts, ["inputs"])]
        ]
        stdout = opts[:json] ? Report.baselines_json(info, rows) : Report.baselines_text(info, rows)
        $stdout.write(stdout)
        write_optional(opts[:json_out], Report.baselines_json(info, rows))
        write_optional(opts[:md_out], Report.baselines_markdown(info, rows))
      end
      0
    end

    def run_strategy(target, entry, user_inputs, type_overrides, opts, strategies)
      Engine.explore(
        target: target,
        entry: entry,
        user_inputs: user_inputs,
        type_overrides: type_overrides,
        seed: opts[:seed],
        strategies: strategies,
        random: opts[:random],
        mutate_cap: opts[:mutate_cap],
        timeout: opts[:timeout],
        command: "baselines",
        requires: opts[:requires],
        load_paths: opts[:load_paths]
      )
    end

    def warn_unnamed(result, target)
      unnamed = Emitters::Support.unnamed_requires(result.requires, (target unless result.target_required), load_paths: result.load_paths)
      unnamed.each do |path|
        $stderr.puts "branchout: #{Target.display_path(path)} is under no -I or --require directory, so the emitted test requires it by path. " \
                     "Pass -I with a directory that holds it to require it by name."
      end
    end

    def write_optional(path, content)
      return unless path

      FileUtils.mkdir_p(File.dirname(File.expand_path(path)))
      File.write(path, content)
    end

    def take(args, flag)
      value = args.shift
      raise Error, "#{flag} needs a value" unless value

      value
    end

    def parse_int(text, label)
      Integer(text)
    rescue ArgumentError
      raise Error, "#{label} must be an integer"
    end

    def parse_timeout(text)
      value = Float(text)
      raise Error, "timeout must be > 0" unless value.positive?

      value == value.to_i ? value.to_i : value
    rescue ArgumentError
      raise Error, "timeout must be a number"
    end

    def parse_keys(text)
      keys = text.split(",").map(&:strip).reject(&:empty?)
      raise Error, "--pin-keys list is empty" if keys.empty?

      keys
    end

    def parse_strategies(text)
      names = text.split(",").map(&:strip).reject(&:empty?)
      unknown = names - Engine::STRATEGY_ORDER
      raise Error, "unknown strategy #{unknown.join(", ")}" unless unknown.empty?
      raise Error, "strategy list is empty" if names.empty?

      Engine::STRATEGY_ORDER.select { |name| names.include?(name) }
    end
  end
end
