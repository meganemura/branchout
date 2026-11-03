# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "open3"
require "fileutils"
require "branchout"

class CLITest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  BIN = File.join(ROOT, "bin/branchout")

  def run_cli(*args)
    Open3.capture3(RbConfig.ruby, BIN, *args.map(&:to_s), chdir: ROOT)
  end

  def write_inputs(dir, body)
    path = File.join(dir, "inputs.json")
    File.write(path, JSON.generate(body))
    path
  end

  def test_help_and_version
    stdout, stderr, status = run_cli("--help")
    assert status.success?
    assert_includes stdout, "branchout explore"
    assert_empty stderr

    stdout, _stderr, status = run_cli("--version")
    assert status.success?
    assert_equal "branchout #{Branchout::VERSION}\n", stdout
  end

  def test_magic_mutation_covers_both_arms_and_is_byte_stable
    stdout, stderr, status = run_cli(
      "explore", "test/fixtures/magic.rb", "FixtureMagic.classify",
      "--strategy", "mutate", "--random", "0", "--seed", "0"
    )
    assert status.success?, stderr
    assert_empty stderr
    assert_includes stdout, "arms_covered: 2"
    assert_includes stdout, "arms_total: 2"
    assert_includes stdout, "cond: x == 114514"
    assert_includes stdout, "input: [114514]"
    assert_includes stdout, "input: [0]"
    assert_includes stdout, "FRONTIER\n(none)"

    again, _, _ = run_cli(
      "explore", "test/fixtures/magic.rb", "FixtureMagic.classify",
      "--strategy", "mutate", "--random", "0", "--seed", "0"
    )
    assert_equal stdout, again
  end

  def test_magic_snapshot
    stdout, _stderr, status = run_cli(
      "explore", "test/fixtures/magic.rb", "FixtureMagic.classify",
      "--strategy", "mutate", "--random", "0", "--seed", "0"
    )
    assert status.success?
    assert_equal <<~OUT, stdout
      branchout explore
      target: test/fixtures/magic.rb
      entry: FixtureMagic.classify
      seed: 0
      strategies: mutate
      random: 0
      mutate_cap: 256
      timeout: 1
      inputs_ran: 0
      mutate_ran: 6
      random_ran: 0
      executions: 6
      arms_covered: 2
      arms_total: 2
      exceptions: 0

      COVERED
      id: if@5:4/else@8:6
      loc: test/fixtures/magic.rb:8:6
      cond: x == 114514
      sense: cond-false
      input: [0]

      id: if@5:4/then@6:6
      loc: test/fixtures/magic.rb:6:6
      cond: x == 114514
      sense: cond-true
      input: [114514]

      FRONTIER
      (none)

      EXCEPTIONS
      (none)
    OUT
  end

  def test_json_has_sorted_ids_and_no_clock
    Dir.mktmpdir do |dir|
      path = write_inputs(dir, { "inputs" => [{ "args" => [0] }] })
      stdout, stderr, status = run_cli(
        "explore", "test/fixtures/magic.rb", "FixtureMagic.classify",
        "--strategy", "inputs", "--random", "0", "--json", "--inputs", path
      )
      assert status.success?, stderr
      data = JSON.parse(stdout)
      assert_equal 1, data["version"]
      assert_equal ["if@5:4/else@8:6"], data["covered"].map { |arm| arm["id"] }
      ids = data["frontier"].map { |arm| arm["id"] }
      assert_equal ids.sort, ids
      assert_equal "reached", data["frontier"].first["parent"]
      assert_equal [0], data["frontier"].first["nearest"]["args"]
      assert_equal false, stdout.include?("timestamp")
      assert_equal false, data.key?("time")
    end
  end

  def test_arithmetic_baselines_do_not_solve_the_congruence
    stdout, stderr, status = run_cli(
      "baselines", "test/fixtures/arith.rb", "FixtureArith.classify",
      "--seed", "1", "--random", "40"
    )
    assert status.success?, stderr
    assert_includes stdout, "random_covered: if@5:4/else@12:6"
    assert_includes stdout, "mutate_covered: if@5:4/else@12:6"
    refute_includes stdout, "if@5:4/then@6:6"
  end

  def test_agent_input_opens_nested_arm
    Dir.mktmpdir do |dir|
      path = write_inputs(dir, { "inputs" => [{ "args" => [0, 0] }, { "args" => [138, 0] }] })
      stdout, stderr, status = run_cli(
        "explore", "test/fixtures/arith.rb", "FixtureArith.classify",
        "--strategy", "inputs", "--random", "0", "--inputs", path
      )
      assert status.success?, stderr
      assert_includes stdout, "cond: y == x + 5"
      assert_includes stdout, "parent: reached"
      assert_includes stdout, "nearest: [138,0]"
      assert_includes stdout, "sense: cond-true"
    end
  end

  def test_callee_branches_are_in_scope_and_unused_method_is_not
    Dir.mktmpdir do |dir|
      path = write_inputs(dir, { "inputs" => [{ "args" => [1] }] })
      stdout, stderr, status = run_cli(
        "explore", "test/fixtures/call.rb", "FixtureCall.entry",
        "--strategy", "inputs", "--random", "0", "--inputs", path
      )
      assert status.success?, stderr
      assert_includes stdout, "cond: x > 10"
      assert_includes stdout, "parent: reached"
      refute_includes stdout, "x == 9"
    end
  end

  def test_each_input_gets_a_new_receiver
    Dir.mktmpdir do |dir|
      path = write_inputs(dir, { "inputs" => [[2], [3]] })
      stdout, stderr, status = run_cli(
        "explore", "test/fixtures/tally.rb", "FixtureTally#bump",
        "--strategy", "inputs", "--random", "0", "--inputs", path
      )
      assert status.success?, stderr
      assert_includes stdout, "arms_covered: 1"
      assert_includes stdout, "FRONTIER\nid: if@10:4/then@11:6"
    end
  end

  def test_new_gives_the_constructor_arguments
    Dir.mktmpdir do |dir|
      path = write_inputs(dir, { "inputs" => [
        { "args" => [5], "new" => [10] },
        { "args" => [12], "new" => { "args" => [10], "kwargs" => { "limit" => 5 } } }
      ] })
      test = File.join(dir, "account_test.rb")
      stdout, stderr, status = run_cli(
        "explore", "test/fixtures/account.rb", "FixtureAccount#withdraw",
        "--strategy", "inputs", "--random", "0", "--inputs", path, "--emit-tests", test
      )
      assert status.success?, stderr
      assert_includes stdout, "arms_covered: 1"
      assert_includes stdout, 'nearest: {"args":[5],"kwargs":{},"new":{"args":[10],"kwargs":{}}}'
      assert_includes File.read(test), "assert_equal 5, FixtureAccount.new(10).withdraw(5)"
      assert_includes File.read(test), "assert_equal -2, FixtureAccount.new(10, limit: 5).withdraw(12)"
      _out, err, status = Open3.capture3(RbConfig.ruby, test)
      assert status.success?, err
    end
  end

  def test_required_constructor_arguments_need_new
    Dir.mktmpdir do |dir|
      path = write_inputs(dir, { "inputs" => [[5]] })
      _stdout, stderr, status = run_cli(
        "explore", "test/fixtures/account.rb", "FixtureAccount#withdraw",
        "--strategy", "inputs", "--random", "0", "--inputs", path
      )
      refute status.success?
      assert_includes stderr, "FixtureAccount#initialize requires 1 arguments; give them in \"new\""
    end
  end

  def test_new_is_refused_for_a_class_method
    Dir.mktmpdir do |dir|
      path = write_inputs(dir, { "inputs" => [{ "args" => [1], "new" => [] }] })
      _stdout, stderr, status = run_cli(
        "explore", "test/fixtures/magic.rb", "FixtureMagic.classify",
        "--strategy", "inputs", "--random", "0", "--inputs", path
      )
      refute status.success?
      assert_includes stderr, "FixtureMagic.classify is not an instance method"
    end
  end

  def test_a_module_function_runs_as_a_class_method
    Dir.mktmpdir do |dir|
      path = write_inputs(dir, { "inputs" => [[1], [0], [-1]] })
      args = ["--strategy", "inputs", "--random", "0", "--inputs", path]
      stdout, stderr, status = run_cli("explore", "test/fixtures/helpers.rb", "FixtureHelpers.sign", *args)
      assert status.success?, stderr
      assert_includes stdout, "arms_covered: 4\narms_total: 4"

      _stdout, stderr, status = run_cli("explore", "test/fixtures/helpers.rb", "FixtureHelpers#sign", *args)
      refute status.success?
      assert_includes stderr, "FixtureHelpers is a module, so its methods have no receiver; target FixtureHelpers.sign"
    end
  end

  def test_an_extend_self_method_runs_as_a_class_method
    Dir.mktmpdir do |dir|
      path = write_inputs(dir, { "inputs" => [[3], [0], [1]] })
      stdout, stderr, status = run_cli(
        "explore", "test/fixtures/helpers.rb", "FixtureExtended.early",
        "--strategy", "inputs", "--random", "0", "--inputs", path
      )
      assert status.success?, stderr
      assert_includes stdout, "arms_covered: 4\narms_total: 4"
    end
  end

  def test_an_entry_with_no_arms_warns
    Dir.mktmpdir do |dir|
      path = write_inputs(dir, { "inputs" => [[1]] })
      stdout, stderr, status = run_cli(
        "explore", "test/fixtures/delegate.rb", "FixtureDelegate.apply",
        "--strategy", "inputs", "--random", "0", "--inputs", path
      )
      assert status.success?, stderr
      assert_includes stdout, "arms_total: 0"
      assert_equal "branchout: FixtureDelegate.apply and its bare callees in test/fixtures/delegate.rb have no branches. " \
                   "A call on another receiver, such as new.method, is not followed; target that method.\n", stderr
    end
  end

  def test_require_loads_the_library_before_the_target
    Dir.mktmpdir do |dir|
      path = write_inputs(dir, { "inputs" => [[0], [4]] })
      args = [
        "explore", "test/fixtures/loaded.rb", "FixtureLoaded.over?",
        "--strategy", "inputs", "--random", "0", "--inputs", path
      ]
      stdout, stderr, status = run_cli(*args)
      assert status.success?, stderr
      assert_includes stdout, "message: uninitialized constant FixtureLoaded::LIMIT"

      test = File.join(dir, "loaded_test.rb")
      stdout, stderr, status = run_cli(*args, "--require", "test/fixtures/loader.rb", "--emit-tests", test)
      assert status.success?, stderr
      assert_includes stdout, "arms_covered: 2"
      assert_includes stdout, "EXCEPTIONS\n(none)"
      source = File.read(test)
      assert_match(/loader\.rb"\nrequire_relative ".*loaded\.rb"/, source)
      _out, err, status = Open3.capture3(RbConfig.ruby, test)
      assert status.success?, err
    end
  end

  def test_division_is_recorded
    Dir.mktmpdir do |dir|
      path = write_inputs(dir, { "inputs" => [{ "args" => [24, 12] }] })
      stdout, stderr, status = run_cli(
        "explore", "test/fixtures/scale.rb", "FixtureScale.scale",
        "--strategy", "inputs", "--random", "0", "--inputs", path
      )
      assert status.success?, stderr
      assert_includes stdout, "class: ZeroDivisionError"
      assert_includes stdout, "loc: test/fixtures/scale.rb:8"
      assert_includes stdout, "message: divided by 0"
    end
  end

  def test_scale_mutation_does_not_raise
    stdout, stderr, status = run_cli(
      "explore", "test/fixtures/scale.rb", "FixtureScale.scale",
      "--strategy", "mutate,random", "--seed", "1", "--random", "40"
    )
    assert status.success?, stderr
    assert_includes stdout, "EXCEPTIONS\n(none)"
  end

  def test_while_not_entered_is_a_reached_parent
    Dir.mktmpdir do |dir|
      path = write_inputs(dir, { "inputs" => [{ "args" => [0] }] })
      stdout, stderr, status = run_cli(
        "explore", "test/fixtures/spin.rb", "FixtureSpin.forever",
        "--strategy", "inputs", "--random", "0", "--inputs", path
      )
      assert status.success?, stderr
      assert_includes stdout, "parent: reached"
      assert_includes stdout, "nearest: [0]"
      assert_includes stdout, "path: (none)"
    end
  end

  def test_timeout_is_a_finding
    Dir.mktmpdir do |dir|
      path = write_inputs(dir, { "inputs" => [{ "args" => [1] }] })
      stdout, stderr, status = run_cli(
        "explore", "test/fixtures/spin.rb", "FixtureSpin.forever",
        "--strategy", "inputs", "--random", "0", "--timeout", "0.2", "--inputs", path
      )
      assert status.success?, stderr
      assert_includes stdout, "class: Timeout::Error"
      assert_includes stdout, "message: execution expired"
      assert_includes stdout, "loc: test/fixtures/spin.rb:4"
    end
  end

  def test_case_condition_text
    Dir.mktmpdir do |dir|
      path = write_inputs(dir, { "inputs" => [{ "args" => ["a", 0] }] })
      stdout, stderr, status = run_cli(
        "explore", "test/fixtures/branches.rb", "FixtureBranches.demo",
        "--strategy", "inputs", "--random", "0", "--inputs", path
      )
      assert status.success?, stderr
      assert_includes stdout, 'cond: when "a", "b"'
    end
  end

  def test_instance_method
    stdout, stderr, status = run_cli(
      "explore", "test/fixtures/box.rb", "FixtureBox#parity",
      "--strategy", "mutate", "--random", "0"
    )
    assert status.success?, stderr
    assert_includes stdout, "arms_covered: 2"
    assert_includes stdout, "arms_total: 2"
    assert_includes stdout, "cond: n.even?"
  end

  def test_emit_tests_passes
    Dir.mktmpdir do |dir|
      inputs = write_inputs(dir, { "inputs" => [{ "args" => [0] }, { "args" => [114514] }] })
      destination = File.join(dir, "generated_test.rb")
      _stdout, stderr, status = run_cli(
        "explore", "test/fixtures/magic.rb", "FixtureMagic.classify",
        "--strategy", "inputs", "--random", "0", "--inputs", inputs,
        "--emit-tests", destination
      )
      assert status.success?, stderr
      source = File.read(destination)
      assert_includes source, "assert_equal :plain, FixtureMagic.classify(0)"
      assert_includes source, "assert_equal :magic, FixtureMagic.classify(114514)"
      refute_match(/Time\.now|timestamp/, source)
      test_out, test_err, test_status = Open3.capture3(RbConfig.ruby, destination)
      assert test_status.success?, test_out + test_err
    end
  end

  def test_reports_are_written
    Dir.mktmpdir do |dir|
      json_path = File.join(dir, "out", "frontier.json")
      md_path = File.join(dir, "out", "frontier.md")
      stdout, stderr, status = run_cli(
        "explore", "test/fixtures/magic.rb", "FixtureMagic.classify",
        "--strategy", "mutate", "--random", "0",
        "--json-out", json_path, "--md-out", md_path
      )
      assert status.success?, stderr
      assert_includes stdout, "branchout explore"
      assert_includes File.read(md_path), "# branchout explore"
      assert_equal stdout, File.read(md_path).sub(/\A# branchout explore\n\n/, "")
      data = JSON.parse(File.read(json_path))
      assert_equal 2, data["arms_covered"]
    end
  end

  def test_usage_errors
    _stdout, stderr, status = run_cli("explore")
    refute status.success?
    assert_includes stderr, "missing TARGET"

    _stdout, stderr, status = run_cli("explore", "test/fixtures/magic.rb", "Missing.mod")
    refute status.success?
    assert_includes stderr, "cannot find"

    _stdout, stderr, status = run_cli("nope")
    refute status.success?
    assert_includes stderr, "unknown command"
  end

  USAGE_ERRORS = {
    %w[explore test/fixtures/magic.rb] => "missing ENTRY",
    %w[explore test/fixtures/magic.rb A.b extra] => "unexpected arguments: extra",
    %w[explore t.rb A.b --seed -1] => "seed must be >= 0",
    %w[explore t.rb A.b --seed x] => "seed must be an integer",
    %w[explore t.rb A.b --random -1] => "random count must be >= 0",
    %w[explore t.rb A.b --mutate-cap -1] => "mutate-cap must be >= 0",
    %w[explore t.rb A.b --timeout 0] => "timeout must be > 0",
    %w[explore t.rb A.b --timeout x] => "timeout must be a number",
    %w[explore t.rb A.b --strategy inputs,guess] => "unknown strategy guess",
    %w[explore t.rb A.b --strategy ,] => "strategy list is empty",
    %w[explore t.rb A.b --inputs] => "--inputs needs a value",
    %w[explore t.rb A.b --verbose] => "unknown option --verbose",
    %w[explore t.rb A.b --format rspec] => "--format requires --emit-tests",
    %w[explore t.rb A.b --emit-tests x.rb --format tap] => "format must be minitest or rspec",
    %w[baselines t.rb A.b --emit-tests x.rb] => "--emit-tests is only valid with explore"
  }.freeze

  def test_each_usage_error_names_the_problem
    USAGE_ERRORS.each do |argv, message|
      error = assert_raises(Branchout::Error, argv.join(" ")) { Branchout::CLI.run(argv) }
      assert_equal message, error.message, argv.join(" ")
    end
  end

  def test_help_after_a_command_prints_help
    status = nil
    stdout, _stderr = capture_io { status = Branchout::CLI.run(%w[explore --help]) }
    assert_equal 0, status
    assert_includes stdout, "Usage:"
  end
end
