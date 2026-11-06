# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "open3"
require "fileutils"
require "branchout"
require_relative "support/cli"

class CLITest < Minitest::Test
  parallelize_me!

  ROOT = File.expand_path("..", __dir__)
  BIN = File.join(ROOT, "bin/branchout")

  def run_cli(*args)
    CLIProcess.run(*args, chdir: ROOT)
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

  def test_mutation_reaches_the_literals_a_private_helper_compares_against
    stdout, stderr, status = run_cli(
      "explore", "test/fixtures/ledger.rb", "FixtureLedger#label",
      "--strategy", "mutate", "--random", "0"
    )
    assert status.success?, stderr
    assert_includes stdout, "covered: 6 of 6 arms"
  end

  def test_magic_mutation_covers_both_arms_and_is_byte_stable
    stdout, stderr, status = run_cli(
      "explore", "--verbose", "test/fixtures/magic.rb", "FixtureMagic.classify",
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
      "explore", "--verbose", "test/fixtures/magic.rb", "FixtureMagic.classify",
      "--strategy", "mutate", "--random", "0", "--seed", "0"
    )
    assert_equal stdout, again
  end

  # The settings of a strategy that did not run are left out.
  def test_the_verbose_report_names_the_settings_of_the_strategies_that_ran
    stdout, _stderr, status = run_cli(
      "explore", "--verbose", "test/fixtures/magic.rb", "FixtureMagic.classify", "--strategy", "inputs,random", "--random", "2"
    )
    assert status.success?
    assert_includes stdout, "entry: FixtureMagic.classify\nseed: 0\nstrategies: inputs,random\nrandom: 2\ntimeout: 1\ninputs_ran: 0\nrandom_ran: 2\n"
  end

  def test_magic_snapshot
    stdout, _stderr, status = run_cli(
      "explore", "--verbose", "test/fixtures/magic.rb", "FixtureMagic.classify",
      "--strategy", "mutate", "--random", "0", "--seed", "0"
    )
    assert status.success?
    assert_equal <<~OUT, stdout
      branchout explore
      target: test/fixtures/magic.rb
      entry: FixtureMagic.classify
      strategies: mutate
      mutate_cap: 256
      timeout: 1
      mutate_ran: 6
      executions: 6
      arms_covered: 2
      arms_total: 2
      exceptions: 0
      callees_not_counted: 0
      operators_not_counted: 0
      boundaries_not_counted: 0

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

      NOT COUNTED
      (none)

      OPERATORS
      (none)

      BOUNDARIES
      (none)
    OUT
  end

  # The default report leads with what to act on: arms an input reached are
  # in line order with what to change, decisions no input reached are one
  # line each, and inputs that raised the same error share one line.
  def test_the_default_report_leads_with_the_frontier
    Dir.mktmpdir do |dir|
      target = File.join(dir, "gate.rb")
      File.write(target, <<~RUBY)
        module Gate
          def self.pick(n, mode)
            raise ArgumentError, "too big" if n > 5
            return :none if n.zero?

            if n.positive?
              case mode
              when "a" then :a
              when "b" then :b
              end
            end || (mode.nil? && :empty)
          end
        end
      RUBY
      inputs = write_inputs(dir, {"inputs" => [[-1, nil], [6, "a"], [7, "a"], [8, "a"], [9, "a"]]})
      stdout, stderr, status = run_cli("explore", target, "Gate.pick", "--inputs", inputs,
                                       "--strategy", "inputs", "--random", "0", "--emit-tests", File.join(dir, "gate_test.rb"))
      assert status.success?, stderr
      assert_equal <<~OUT, stdout
        branchout explore #{target} Gate.pick
        covered: 4 of 9 arms by 5 inputs
        raised: 4 inputs
        tests: #{dir}/gate_test.rb

        FRONTIER (add an input like the nearest above each arm, changed as the arm says)
        nearest: [-1,null]
        #{target}:4:4 makes `n.zero?` true
        #{target}:7:6 makes `n.positive?` true

        not reached yet; take the arms above first:
        #{target}:7 case (3 arms)

        EXCEPTIONS
        ArgumentError at #{target}:3: too big
          inputs: [6,"a"], [7,"a"], [8,"a"] and 1 more

        OPERATORS (coverage does not see which side ran; vary each left side)
        #{target}:11:8 || in `if n.positive? case mode when "a" then :a when "b" then :b end end || (mode.nil? && :empty)`
        #{target}:11:22 && in `mode.nil? && :empty`

        BOUNDARIES (each comparison in the counted code, listed whether or not an input made both sides equal; coverage does not see which did)
        #{target}:3:40 > in `n > 5`

        Pass --verbose for every covered arm and the run settings.
      OUT

      raising = write_inputs(dir, {"inputs" => [[nil, "a"]]})
      stdout, stderr, status = run_cli("explore", target, "Gate.pick", "--inputs", raising, "--strategy", "inputs", "--random", "0")
      assert status.success?, stderr
      assert_includes stdout, "\nFRONTIER\nno input reached these decisions:\n#{target}:3 n > 5 (2 arms)\n#{target}:4 n.zero? (2 arms)\n"
    end
  end

  def test_each_run_of_arms_with_one_nearest_input_gets_its_own_nearest_line
    Dir.mktmpdir do |dir|
      target = File.join(dir, "pair.rb")
      File.write(target, <<~RUBY)
        module Pair
          def self.pick(a, b)
            return(b > 5 ? :both : :a) if a > 5
            b > 5 ? :b : :none
          end
        end
      RUBY
      inputs = write_inputs(dir, {"inputs" => [[6, 0], [0, 0]]})
      stdout, stderr, status = run_cli("explore", target, "Pair.pick", "--inputs", inputs, "--strategy", "inputs", "--random", "0")
      assert status.success?, stderr
      assert_includes stdout, "nearest: [6,0]\n#{target}:3:19 makes `b > 5` true\nnearest: [0,0]\n#{target}:4:12 makes `b > 5` true\n"
    end
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
      assert_includes stdout, "nearest: [138,0]\ntest/fixtures/arith.rb:7:8 makes `y == x + 5` true\n"
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
      assert_includes stdout, "test/fixtures/call.rb:14:6 makes `x > 10` true\n"
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
      assert_includes stdout, "covered: 1 of "
      assert_includes stdout, "nearest: [2]\ntest/fixtures/tally.rb:11:6 makes `@seen > 3` true\n"
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
      assert_includes stdout, "covered: 1 of "
      assert_includes stdout, 'nearest: {"args":[5],"new":{"args":[10]}}'
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
      assert_includes stderr, "FixtureAccount#initialize requires 1 argument; give it in \"new\""
    end
  end

  # A required keyword is a required argument too: without "new" every
  # input would raise ArgumentError from initialize, not from the entry.
  # A "new" with only keywords needs no "args".
  def test_required_constructor_keywords_need_new
    Dir.mktmpdir do |dir|
      target = File.join(dir, "kw.rb")
      File.write(target, "class Kw\n  def initialize(main:, side:) = @main = main\n  def pick(x) = x > 0 ? :pos : :neg\nend\n")
      _stdout, stderr, status = run_cli("explore", "--verbose", target, "Kw#pick", "--strategy", "inputs", "--random", "0",
                                        "--inputs", write_inputs(dir, { "inputs" => [[1]] }))
      refute status.success?
      assert_includes stderr, "Kw#initialize requires the keywords main:, side:; give them in \"new\""
      one = File.join(dir, "kw1.rb")
      File.write(one, "class Kw\n  def initialize(size, main:) = @main = main\n  def pick(x) = x > 0 ? :pos : :neg\nend\n")
      _stdout, stderr, _status = run_cli("explore", "--verbose", one, "Kw#pick", "--strategy", "inputs", "--random", "0",
                                         "--inputs", write_inputs(dir, { "inputs" => [[1]] }))
      assert_includes stderr, "Kw#initialize requires 1 argument and the keyword main:; give them in \"new\""
      File.write(one, "class Kw\n  def initialize(main:) = @main = main\n  def pick(x) = x > 0 ? :pos : :neg\nend\n")
      _stdout, stderr, _status = run_cli("explore", "--verbose", one, "Kw#pick", "--strategy", "inputs", "--random", "0",
                                         "--inputs", write_inputs(dir, { "inputs" => [[1]] }))
      assert_includes stderr, "Kw#initialize requires the keyword main:; give it in \"new\""
      path = write_inputs(dir, { "inputs" => [-1, 1].map { |x| { "args" => [x], "new" => { "kwargs" => { "main" => 1, "side" => 2 } } } } })
      stdout, stderr, status = run_cli("explore", "--verbose", target, "Kw#pick", "--strategy", "inputs", "--random", "0", "--inputs", path)
      assert status.success?, stderr
      assert_includes stdout, "arms_covered: 2\narms_total: 2\nexceptions: 0\n"
    end
  end

  def test_setup_calls_build_the_receiver_state_before_the_entry
    Dir.mktmpdir do |dir|
      path = write_inputs(dir, { "inputs" => [
        { "args" => [], "setup" => [{ "method" => "add", "args" => ["apple", 3] }] },
        { "args" => [], "new" => ["EUR"], "setup" => [
          { "method" => "add", "args" => ["apple", 5] },
          { "method" => "add", "args" => ["pear", 5], "kwargs" => { "price" => 50 } }
        ] },
        { "args" => [], "setup" => [{ "method" => "add", "args" => ["apple", 0] }] }
      ] })
      test = File.join(dir, "cart_test.rb")
      spec = File.join(dir, "cart_spec.rb")
      stdout = nil
      [test, spec].each do |out|
        stdout, stderr, status = run_cli(
          "explore", "--verbose", "test/fixtures/cart.rb", "FixtureCart#volume_discount_cents",
          "--strategy", "inputs", "--random", "0", "--inputs", path, "--emit-tests", out
        )
        assert status.success?, stderr
      end
      # The setup's own call to size takes the empty arm; only the entry's
      # calls count, so that arm stays on the frontier.
      assert_includes stdout, "arms_covered: 4\narms_total: 6"
      assert_includes stdout, "id: if@28:4/then@28:20\nloc: test/fixtures/cart.rb:28:20\ncond: @items.empty?\nsense: cond-true\nparent: reached"
      assert_includes stdout, "class: ArgumentError\nloc: test/fixtures/cart.rb:10\n" \
                              'input: {"args":[],"setup":[{"args":["apple",0],"method":"add"}]}' \
                              "\nmessage: quantity must be positive"

      source = File.read(test)
      assert_includes source, "    fixture_cart = FixtureCart.new\n    fixture_cart.add(\"apple\", 3)\n" \
                              "    assert_equal 100, fixture_cart.volume_discount_cents\n"
      assert_includes source, "    fixture_cart = FixtureCart.new(\"EUR\")\n    fixture_cart.add(\"apple\", 5)\n" \
                              "    fixture_cart.add(\"pear\", 5, price: 50)\n" \
                              "    assert_equal 500, fixture_cart.volume_discount_cents\n"
      assert_includes source, "    error = assert_raises(ArgumentError) do\n      fixture_cart = FixtureCart.new\n" \
                              "      fixture_cart.add(\"apple\", 0)\n      fixture_cart.volume_discount_cents\n    end\n"
      _out, err, status = Open3.capture3(RbConfig.ruby, test)
      assert status.success?, err
      # The input that raises keeps its setup inside the expect block, so
      # the raise is pinned wherever it comes from.
      assert_includes File.read(spec), "    context \"with new\" do\n      let(:fixture_cart) { described_class.new }\n\n" \
                                       "      it 'raises ArgumentError after add(\"apple\", 0)' do\n        expect {\n" \
                                       "          fixture_cart.add(\"apple\", 0)\n          volume_discount_cents\n" \
                                       "        }.to raise_error(ArgumentError, \"quantity must be positive\")\n"
      _out, err, status = Open3.capture3(RbConfig.ruby, "-rrspec/autorun", "-e", "", spec)
      assert status.success?, err
    end
  end

  def test_setup_is_refused_for_a_class_method
    Dir.mktmpdir do |dir|
      path = write_inputs(dir, { "inputs" => [{ "args" => [1], "setup" => [{ "method" => "add", "args" => [] }] }] })
      _stdout, stderr, status = run_cli(
        "explore", "test/fixtures/magic.rb", "FixtureMagic.classify",
        "--strategy", "inputs", "--random", "0", "--inputs", path
      )
      refute status.success?
      assert_includes stderr, "FixtureMagic.classify is not an instance method, so its inputs take no \"setup\""
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

  # A receiver an input's Ruby builds, such as a saved record from a
  # factory, takes the name the emitted test gives it, so its arguments can
  # be read from it.
  def test_a_receiver_built_by_ruby_is_named_for_its_arguments
    Dir.mktmpdir do |dir|
      path = write_inputs(dir, { "inputs" => [
        { "receiver" => { "ruby" => "FixtureAccount.new(10)" }, "args" => [{ "ruby" => "fixture_account.withdraw(4)" }] },
        { "receiver" => { "ruby" => "FixtureAccount.new(1, limit: 2)" }, "args" => [5] }
      ] })
      minitest = File.join(dir, "account_test.rb")
      rspec = File.join(dir, "account_spec.rb")
      [minitest, rspec].each do |out|
        stdout, stderr, status = run_cli(
          "explore", "--verbose", "test/fixtures/account.rb", "FixtureAccount#withdraw",
          "--strategy", "inputs", "--inputs", path, "--emit-tests", out
        )
        assert status.success?, stderr
        assert_includes stdout, "arms_covered: 2\n"
        assert_includes stdout, 'input: {"args":[{"ruby":"fixture_account.withdraw(4)"}],"receiver":{"ruby":"FixtureAccount.new(10)"}}'
      end
      assert_includes File.read(minitest), "    fixture_account = FixtureAccount.new(10)\n" \
                                           "    assert_equal 4, fixture_account.withdraw(fixture_account.withdraw(4))\n"
      assert_includes File.read(rspec), "let(:fixture_account) { FixtureAccount.new(10) }"
      assert_includes File.read(rspec), "expect(fixture_account.withdraw(fixture_account.withdraw(4))).to eq(4)"
      [minitest, rspec].each do |out|
        command = out.end_with?("_spec.rb") ? ["-rrspec/core", "-e", "exit RSpec::Core::Runner.run(ARGV)", "--", out] : [out]
        stdout, stderr, status = Open3.capture3(RbConfig.ruby, *command, chdir: ROOT)
        assert status.success?, stdout + stderr
      end
    end
  end

  # A Rails app's config/environment.rb sits beside config/puma.rb, so its
  # directory must not come before the gems on the load path.
  def test_a_require_files_directory_does_not_shadow_a_library
    stdout, stderr, status = run_cli(
      "explore", "test/fixtures/tally.rb", "FixtureTally#bump", "--require", "test/fixtures/boot/environment.rb",
      "--strategy", "mutate"
    )
    assert status.success?, stderr
    assert_includes stdout, "covered: 2 of "
  end

  def test_a_receiver_is_ruby_and_replaces_new
    {
      { "args" => [1], "receiver" => "FixtureAccount.new(1)" } => "inputs[0] receiver must be Ruby such as {\"ruby\": \"create(:loan)\"}",
      { "args" => [1], "new" => [1], "receiver" => { "ruby" => "FixtureAccount.new(1)" } } =>
        "inputs[0] gives both new and receiver; receiver builds the object itself"
    }.each do |entry, message|
      Dir.mktmpdir do |dir|
        path = write_inputs(dir, { "inputs" => [entry] })
        _stdout, stderr, status = run_cli(
          "explore", "test/fixtures/account.rb", "FixtureAccount#withdraw", "--strategy", "inputs", "--inputs", path
        )
        refute status.success?
        assert_includes stderr, message
      end
    end
  end

  def test_a_module_function_runs_as_a_class_method
    Dir.mktmpdir do |dir|
      path = write_inputs(dir, { "inputs" => [[1], [0], [-1]] })
      args = ["--strategy", "inputs", "--random", "0", "--inputs", path]
      stdout, stderr, status = run_cli("explore", "test/fixtures/helpers.rb", "FixtureHelpers.sign", *args)
      assert status.success?, stderr
      assert_includes stdout, "covered: 4 of 4 arms"

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
      assert_includes stdout, "covered: 4 of 4 arms"
    end
  end

  def test_a_class_method_is_followed_through_new_to_the_instance_method
    Dir.mktmpdir do |dir|
      path = write_inputs(dir, { "inputs" => [[1], [-1]] })
      stdout, stderr, status = run_cli(
        "explore", "test/fixtures/delegate.rb", "FixtureDelegate.apply",
        "--strategy", "inputs", "--random", "0", "--inputs", path
      )
      assert status.success?, stderr
      assert_includes stdout, "covered: 2 of 2 arms"
      assert_empty stderr

      path = write_inputs(dir, { "inputs" => [["# a"], ["b"]] })
      stdout, stderr, status = run_cli(
        "explore", "test/fixtures/delegate.rb", "FixtureDocument.apply",
        "--strategy", "inputs", "--random", "0", "--inputs", path
      )
      assert status.success?, stderr
      assert_includes stdout, "covered: 3 of 4 arms"
      assert_includes stdout, "nearest: [\"b\"]\ntest/fixtures/delegate.rb:17:24 makes `doc.empty?` true\n"
    end
  end

  # new(text).tap(&:read) calls read on the instance too.
  def test_a_class_method_is_followed_through_tap_on_new
    Dir.mktmpdir do |dir|
      path = write_inputs(dir, { "inputs" => [["a=1"]] })
      stdout, stderr, status = run_cli(
        "explore", "test/fixtures/delegate.rb", "FixtureParser.parse",
        "--strategy", "inputs", "--random", "0", "--inputs", path
      )
      assert status.success?, stderr
      assert_includes stdout, "covered: 1 of 2 arms"
      assert_includes stdout, "nearest: [\"a=1\"]\ntest/fixtures/delegate.rb:35:42 makes `@text.include?(\"=\")` false\n"
    end
  end

  # Only a call on an instance the method builds with new is followed, and
  # a tap with a block, or a method with no body, follows nothing.
  def test_a_call_on_another_value_or_a_tap_block_is_not_followed
    Dir.mktmpdir do |dir|
      path = write_inputs(dir, { "inputs" => [[1]] })
      %w[FixtureMaker.apply FixtureMaker.inspected FixtureMaker.nothing].each do |entry|
        inputs = entry.end_with?("apply") ? path : write_inputs(dir, { "inputs" => [[]] })
        stdout, stderr, status = run_cli(
          "explore", "--verbose", "test/fixtures/delegate.rb", entry,
          "--strategy", "inputs", "--random", "0", "--inputs", inputs
        )
        assert status.success?, stderr
        assert_includes stdout, "arms_total: 0\n", entry
      end
    end
  end

  # Branch coverage counts no arm for ||, &&, ||=, or &&=, so a method that
  # branches only through them would read as 0 of 0 arms, fully covered.
  def test_operators_that_branch_without_an_arm_are_listed
    Dir.mktmpdir do |dir|
      path = write_inputs(dir, { "inputs" => [[{ "paid" => true }]] })
      stdout, stderr, status = run_cli(
        "explore", "--verbose", "test/fixtures/operators.rb", "FixtureGate.ready?",
        "--strategy", "inputs", "--random", "0", "--inputs", path
      )
      assert status.success?, stderr
      assert_includes stdout, "arms_total: 0\nexceptions: 0\ncallees_not_counted: 0\noperators_not_counted: 2\n"
      assert stdout.end_with?(<<~OUT), stdout
        OPERATORS
        loc: test/fixtures/operators.rb:5:17
        op: &&
        text: order[:paid] && !order[:cancelled]

        loc: test/fixtures/operators.rb:5:39
        op: ||
        text: order[:paid] && !order[:cancelled] || order[:forced]

        BOUNDARIES
        (none)
      OUT
      assert_equal "branchout: FixtureGate.ready? and the methods it calls in test/fixtures/operators.rb have no arm that " \
                   "branch coverage counts, but it branches at the operators OPERATORS lists, and coverage does not see which side of " \
                   "||, &&, ||=, or &&= ran. Give inputs that make each left side truthy and falsy. " \
                   "--emit-tests still pins the return value or error of each input.\n", stderr
    end
  end

  # Coverage takes no arm at a comparison, so every arm can be covered while
  # no input sits on the boundary, where > and >= part.
  def test_comparisons_are_listed_as_boundaries
    Dir.mktmpdir do |dir|
      on = { "ruby" => "Date.new(2026, 4, 1)" }
      path = write_inputs(dir, { "inputs" => [{ "args" => [{ "ruby" => "{start: '2026-01-01'}" }], "kwargs" => { "on" => on } },
                                              { "args" => [{ "ruby" => "{start: '2026-04-02'}" }], "kwargs" => { "on" => on } }] })
      stdout, stderr, status = run_cli("explore", "test/fixtures/window.rb", "FixtureWindow.open_on?", "--strategy", "inputs", "--inputs", path)
      assert status.success?, stderr
      assert_includes stdout, "covered: 2 of 2 arms by 2 inputs\n"
      assert_includes stdout, "\nBOUNDARIES (each comparison in the counted code, listed whether or not an input made both sides equal; coverage does not see which did)\n" \
                              "test/fixtures/window.rb:8:50 > in `start_date > on`\n" \
                              "test/fixtures/window.rb:11:24 < in `on < end_date`\n"
      stdout, stderr, status = run_cli("explore", "test/fixtures/window.rb", "FixtureWindow.open_on?", "--strategy", "inputs", "--inputs", path, "--json")
      assert status.success?, stderr
      assert_equal [%w[> start_date\ >\ on], %w[< on\ <\ end_date]],
                   JSON.parse(stdout)["boundaries_not_counted"].map { |found| [found["op"], found["text"]] }
      stdout, _stderr, _status = run_cli("explore", "--verbose", "test/fixtures/window.rb", "FixtureWindow.open_on?", "--strategy", "inputs",
                                         "--inputs", path)
      assert_includes stdout, "operators_not_counted: 3\nboundaries_not_counted: 2\n"
      assert_includes stdout, "\nBOUNDARIES\nloc: test/fixtures/window.rb:8:50\nop: >\ntext: start_date > on\n"
      stdout, _stderr, _status = run_cli("explore", "test/fixtures/operators.rb", "FixtureGate.allow?", "--strategy", "inputs",
                                         "--inputs", write_inputs(dir, { "inputs" => [[nil, true]] }))
      refute_includes stdout, "BOUNDARIES"
    end
  end

  # An @ivar ||= or &&= on an ivar the file writes nowhere else memoizes
  # across calls on one object, which each input builds anew, so no input
  # varies its left side and OPERATORS leaves it out. One on an ivar that
  # new sets, and a local's ||=, stay.
  def test_memoizing_an_ivar_is_not_listed_as_an_operator
    Dir.mktmpdir do |dir|
      target = File.join(dir, "rates.rb")
      File.write(target, <<~RUBY)
        class Rates
          def initialize(table = nil) = @table = table
          def rate(code, fallback = nil)
            fallback ||= 0
            @cache ||= {}
            @cache[code] ||= lookup(code) || fallback
          end
          def lookup(code)
            @table ||= { "a" => 1 }
            @seen &&= true
            @table[code]
          end
        end
      RUBY
      stdout, stderr, status = run_cli("explore", target, "Rates#rate", "--strategy", "inputs", "--inputs", write_inputs(dir, { "inputs" => [["a"]] }))
      assert status.success?, stderr
      operators = stdout[/^OPERATORS.*?\n\n/m] || stdout[/^OPERATORS.*\z/m]
      assert_includes operators, "fallback ||= 0"
      assert_includes operators, "@table ||= { \"a\" => 1 }"
      refute_includes operators, "@cache ||= {}"
      refute_includes operators, "@seen &&= true"
    end
  end

  # A method whose only branch is a memo gets a hint that names the memo
  # and says what an input cannot do and what to do instead.
  def test_a_method_whose_only_branch_is_a_memo_says_how_to_test_the_memo
    Dir.mktmpdir do |dir|
      target = File.join(dir, "quote.rb")
      File.write(target, "class Quote\n  def total = @total ||= Pricing.sum(1, 2)\nend\nmodule Pricing\n  def self.sum(a, b) = a + b\nend\n")
      _stdout, stderr, status = run_cli("explore", target, "Quote#total", "--strategy", "inputs", "--random", "0",
                                        "--inputs", write_inputs(dir, { "inputs" => [[]] }))
      assert status.success?, stderr
      assert_equal "branchout: Quote#total and the methods it calls in #{target} have no arm that branch coverage counts, " \
                   "and their only branch is the memo `@total ||= Pricing.sum(1, 2)` at #{target}:2:21. Its cached side runs " \
                   "only on a second call on the same object, which no input makes. Explore the methods its right side calls " \
                   "(NOT COUNTED lists those in other files), and test the memo by hand: call the method twice on one object " \
                   "and check that the second call returns the first value without running the right side again. " \
                   "--emit-tests still pins the return value or error of each input.\n", stderr
    end
  end

  # An error whose message differs between two runs, as one that quotes a
  # generated id does, is pinned by its class alone.
  def test_an_error_whose_message_differs_between_runs_is_pinned_by_its_class
    Dir.mktmpdir do |dir|
      target = File.join(dir, "lookup.rb")
      File.write(target, <<~RUBY)
        require "securerandom"

        module Lookup
          def self.find(key)
            raise KeyError, "no row \#{SecureRandom.uuid}" if key.empty?
            raise ArgumentError, "bad key" if key == "?"

            key
          end
        end
      RUBY
      test = File.join(dir, "lookup_test.rb")
      _out, err, status = run_cli("explore", target, "Lookup.find", "--strategy", "inputs", "--inputs",
                                  write_inputs(dir, { "inputs" => [[""], ["?"]] }), "--emit-tests", test)
      assert status.success?, err
      emitted = File.read(test)
      assert_includes emitted, "    error = assert_raises(KeyError) do\n      Lookup.find(\"\")\n    end\n  end\n"
      assert_includes emitted, "    assert_equal \"bad key\", error.message\n"
      _out, err, status = Open3.capture3(RbConfig.ruby, test)
      assert status.success?, err
    end
  end

  # An input that raises on one run and returns on the other has no test,
  # and a file with no other input says so in the words of NOT PINNED.
  def test_an_input_that_raises_on_only_one_run_has_no_test
    Dir.mktmpdir do |dir|
      target = File.join(dir, "flip.rb")
      File.write(target, <<~RUBY)
        module Flip
          def self.call(key)
            @calls = (@calls || 0) + 1
            raise ArgumentError, "odd" if @calls.odd?

            nil
          end
        end
      RUBY
      test = File.join(dir, "flip_test.rb")
      _out, err, status = run_cli("explore", target, "Flip.call", "--strategy", "inputs", "--inputs",
                                  write_inputs(dir, { "inputs" => [["a"]] }), "--emit-tests", test)
      assert status.success?, err
      assert_includes err, "branchout: [\"a\"] returned a value that differed between two runs, so it has no test.\n"
      assert_includes File.read(test), "  def test_no_input_pinned\n"
      assert_includes File.read(test), "skip \"each input returned a value that differed between two runs, so no emitted test checks it\""
      spec = File.join(dir, "flip_spec.rb")
      _out, err, status = run_cli("explore", target, "Flip.call", "--strategy", "inputs", "--inputs",
                                  write_inputs(dir, { "inputs" => [["a"]] }), "--emit-tests", spec)
      assert status.success?, err
      assert_includes File.read(spec), "    it \"pins no input\" do\n      skip \"each input returned a value that differed between two runs, " \
                                       "so no emitted test checks it\"\n    end\n"
    end
  end

  # A generated id beside a Date: the Date is pinned by its value, and the
  # test pins every key but the id.
  def test_a_hash_with_a_varying_id_pins_its_other_keys_and_a_date_by_value
    Dir.mktmpdir do |dir|
      inputs = write_inputs(dir, { "inputs" => [["A", { "ruby" => "Date.new(2026, 4, 1)" }], ["B", nil]] })
      spec = File.join(dir, "stamp_spec.rb")
      test = File.join(dir, "stamp_test.rb")
      [spec, test].each do |out|
        _out, err, status = run_cli("explore", "test/fixtures/stamp.rb", "Stamp.attributes_from", "--strategy", "inputs",
                                    "--inputs", inputs, "--emit-tests", out)
        assert status.success?, err
        assert_includes err, "returned a Hash whose part_id differed between two runs, so its test pins only name, start_at, end_at.\n"
      end
      assert_includes File.read(spec),
                      "expect(described_class.attributes_from(\"A\", Date.new(2026, 4, 1))).to " \
                      "include({ name: \"n\", start_at: Date.new(2026, 4, 1), end_at: nil })\n"
      assert_includes File.read(test), "    assert_equal({ name: \"n\", start_at: Date.new(2026, 4, 1), end_at: nil }, " \
                                       "Stamp.attributes_from(\"A\", Date.new(2026, 4, 1)).slice(:name, :start_at, :end_at))\n"
      out, err, status = Open3.capture3(RbConfig.ruby, "-rrspec/autorun", "-e", "", spec)
      assert status.success?, out + err
      assert_includes out, "2 examples, 0 failures"
      out, err, status = Open3.capture3(RbConfig.ruby, test)
      assert status.success?, out + err
      assert_includes out, "2 runs, 3 assertions, 0 failures"

      # A Time has no literal, so minitest pins it by its class beside the
      # literal keys, and the report names it.
      inputs = write_inputs(dir, { "inputs" => [["A", { "ruby" => "Time.at(0)" }], ["A", { "ruby" => "Date.new(2026, 4, 1)" }]] })
      out, err, status = run_cli("explore", "test/fixtures/stamp.rb", "Stamp.attributes_from", "--strategy", "inputs",
                                 "--inputs", inputs, "--emit-tests", test)
      assert status.success?, err
      assert_includes out, "\nPINNED BY CLASS (the emitted tests check only the class of these returned values, which have no Ruby literal; " \
                           "assert what matters in each by hand)\nvalue[:start_at] is a Time: [\"A\",{\"ruby\":\"Time.at(0)\"}]\n"
      refute_includes out, "Date.new(2026, 4, 1)\"}]\n"
      # The JSON report holds the same parts, with every input, with or
      # without --emit-tests.
      out, err, status = run_cli("explore", "test/fixtures/stamp.rb", "Stamp.attributes_from", "--strategy", "inputs",
                                 "--inputs", inputs, "--json")
      assert status.success?, err
      assert_equal [{ "path" => "value[:start_at]", "class" => "Time",
                      "inputs" => [{ "args" => ["A", { "ruby" => "Time.at(0)" }], "kwargs" => {} }] }],
                   JSON.parse(out)["pinned_by_class"]

      # A value that differed as a whole between two runs has no test, so
      # it is under NOT PINNED's warning and not PINNED BY CLASS.
      grow = File.join(dir, "grow.rb")
      File.write(grow, "module Grow\n  def self.items(n) = Array.new((@calls = (@calls || 0) + 1)) { Object.new }\nend\n")
      out, err, status = run_cli("explore", grow, "Grow.items", "--strategy", "inputs", "--inputs", write_inputs(dir, { "inputs" => [[1]] }),
                                 "--emit-tests", File.join(dir, "grow_test.rb"))
      assert status.success?, err
      assert_includes err, "differed between two runs"
      refute_includes out, "PINNED BY CLASS"
      out, err, status = run_cli("explore", grow, "Grow.items", "--strategy", "inputs", "--inputs", write_inputs(dir, { "inputs" => [[1]] }), "--json")
      assert status.success?, err
      assert_equal [], JSON.parse(out)["pinned_by_class"]
      assert_includes File.read(test), "    value = Stamp.attributes_from(\"A\", Time.at(0))\n" \
                                       "    assert_equal({ name: \"n\", end_at: nil }, value.slice(:name, :end_at))\n" \
                                       "    assert_kind_of Time, value[:start_at]\n"
      out, err, status = Open3.capture3(RbConfig.ruby, test)
      assert status.success?, out + err
    end
  end

  # An arm whose only input differed as a whole between two runs has no
  # test, so the report names it beside the arms it counts as covered.
  # An Enumerable method called on self, such as select, runs the class's
  # own each, so the arms each reaches are counted from the entry.
  def test_an_enumerable_method_on_self_counts_the_arms_each_reaches
    Dir.mktmpdir do |dir|
      items = '[Picks::Item.new(start: nil, ok: true, name: "a"), Picks::Item.new(start: 1, ok: true, name: "b")]'
      inputs = write_inputs(dir, { "inputs" => [{ "new" => [{ "ruby" => items }], "args" => [] }] })
      stdout, stderr, status = run_cli("explore", "test/fixtures/picks.rb", "Picks#names", "--strategy", "inputs", "--inputs", inputs)
      assert status.success?, stderr
      assert_empty stderr
      assert_includes stdout, "covered: 2 of 2 arms by 1 input\n"
    end
  end

  def test_an_arm_whose_only_input_has_no_test_is_reported_as_not_pinned
    Dir.mktmpdir do |dir|
      inputs = write_inputs(dir, { "inputs" => [["A"], ["B"]] })
      args = ["explore", "test/fixtures/stamp.rb", "Stamp.token", "--strategy", "inputs", "--inputs", inputs]
      stdout, err, status = run_cli(*args)
      assert status.success?, err
      assert_includes stdout, "covered: 2 of 2 arms by 2 inputs\n"
      assert_includes stdout, "\nNOT PINNED (each input that took these arms returned a value that differed between two runs, " \
                              "so no emitted test checks them)\n" \
                              "input: [\"A\"]\n" \
                              "test/fixtures/stamp.rb:16:4 makes `code == \"A\"` true\n"
      stdout, err, status = run_cli(*args, "--json")
      assert status.success?, err
      report = JSON.parse(stdout)
      stdout, err, status = run_cli(*args, "--verbose")
      assert status.success?, err
      assert_includes stdout, "input: [\"A\"]\npinned: no, the input differed between two runs\n"
      assert_equal [{ "id" => "unless@16:4/else@16:4", "loc" => "test/fixtures/stamp.rb:16:4", "line" => 16, "column" => 4,
                      "cond" => "code == \"A\"", "sense" => "cond-true", "input" => { "args" => ["A"], "kwargs" => {} } }],
                   report["arms_not_pinned"]

      stdout, err, status = run_cli("explore", "test/fixtures/stamp.rb", "Stamp.attributes_from", "--strategy", "inputs",
                                    "--inputs", write_inputs(dir, { "inputs" => [["A", nil], ["B", nil]] }), "--json")
      assert status.success?, err
      assert_equal [], JSON.parse(stdout)["arms_not_pinned"]

      # An input that returned the same value both times witnesses the arm.
      stdout, err, status = run_cli(*args.first(6), write_inputs(dir, { "inputs" => [["A"], ["A", "t"]] }), "--verbose")
      assert status.success?, err
      assert_includes stdout, "sense: cond-true\ninput: [\"A\",\"t\"]\n"
      refute_includes stdout, "pinned: no"
    end
  end

  def test_operators_sit_beside_the_arms_of_safe_navigation_and_in_json
    Dir.mktmpdir do |dir|
      path = write_inputs(dir, { "inputs" => [[nil, true]] })
      stdout, stderr, status = run_cli(
        "explore", "test/fixtures/operators.rb", "FixtureGate.allow?",
        "--strategy", "inputs", "--random", "0", "--inputs", path, "--json"
      )
      assert status.success?, stderr
      report = JSON.parse(stdout)
      assert_equal [2, 1], [report["arms_total"], report["arms_covered"]]
      assert_equal [{ "loc" => "test/fixtures/operators.rb:9:24", "line" => 9, "column" => 24, "op" => "||",
                      "text" => "user&.fetch(:admin) || force" }], report["operators_not_counted"]
      assert_equal "", stderr

      stdout, stderr, status = run_cli(
        "explore", "test/fixtures/operators.rb", "FixtureGate.settle",
        "--strategy", "inputs", "--random", "0", "--inputs", write_inputs(dir, { "inputs" => [[{}]] }), "--json"
      )
      assert status.success?, stderr
      assert_equal [["||=", "options[:mode] ||= \"auto\""], ["&&=", "options[:trace] &&= options[:mode] == \"debug\""]],
                   JSON.parse(stdout)["operators_not_counted"].map { |found| [found["op"], found["text"]] }
    end
  end

  def test_an_entry_with_no_arms_warns
    Dir.mktmpdir do |dir|
      path = write_inputs(dir, { "inputs" => [[1]] })
      stdout, stderr, status = run_cli(
        "explore", "--verbose", "test/fixtures/delegate.rb", "FixtureDelegate.forward",
        "--strategy", "inputs", "--random", "0", "--inputs", path
      )
      assert status.success?, stderr
      assert_includes stdout, "arms_total: 0"
      assert_equal "branchout: FixtureDelegate.forward and the methods it calls in test/fixtures/delegate.rb have no branches. " \
                   "Only a bare call, a self. call, and a call on new are followed; target the method that branches. " \
                   "--emit-tests still pins the return value or error of each input.\n", stderr
    end
  end

  def test_require_loads_the_library_before_the_target
    Dir.mktmpdir do |dir|
      path = write_inputs(dir, { "inputs" => [[0], [4]] })
      args = [
        "explore", "--verbose", "test/fixtures/loaded.rb", "FixtureLoaded.over?",
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
      # loader.rb requires the target, so the test requires loader.rb alone.
      assert_match(/^require_relative ".*loader\.rb"\n\n/, source)
      refute_match(/loaded\.rb/, source.lines.grep(/require/).join)
      _out, err, status = Open3.capture3(RbConfig.ruby, test)
      assert status.success?, err
    end
  end

  # A target from another checkout of branchout reopens the tool's own
  # classes in the tool's process, so the run would mix two versions.
  def test_a_target_that_loads_another_copy_of_branchout_is_refused
    Dir.mktmpdir do |dir|
      FileUtils.cp_r(File.join(ROOT, "lib"), dir)
      path = write_inputs(dir, { "inputs" => [[1.5]] })
      _stdout, stderr, status = run_cli(
        "explore", File.join(dir, "lib/branchout/canon.rb"), "Branchout::Canon.format_float",
        "--require", File.join(dir, "lib/branchout.rb"), "--strategy", "inputs", "--random", "0", "--inputs", path
      )
      refute status.success?
      assert_equal "branchout: #{File.join(dir, "lib/branchout.rb")} loads another copy of branchout, which replaces " \
                   "the running one's classes. Run that copy's own bin/branchout instead.\n", stderr
    end
  end

  # Each input's arms are its own: counts left over from the input before
  # would give ["a",0] the else arm of ["z",0] too, and make ["z",0] the
  # nearest input with fewer taken arms.
  def test_an_input_takes_only_its_own_arms
    Dir.mktmpdir do |dir|
      path = write_inputs(dir, { "inputs" => [["z", 0], ["a", 0]] })
      stdout, stderr, status = run_cli(
        "explore", "--verbose", "test/fixtures/branches.rb", "FixtureBranches.demo",
        "--strategy", "inputs", "--random", "0", "--inputs", path
      )
      assert status.success?, stderr
      assert_includes stdout, "nearest: [\"a\",0]\npath: case@5:12/when@7:14\n\nid: while@13:4/body@14:6"
    end
  end

  # A call the target file makes while it loads is not an input's.
  def test_a_call_made_while_loading_is_not_counted
    Dir.mktmpdir do |dir|
      target = File.join(dir, "early.rb")
      File.write(target, "module Early\n  def self.f(x)\n    x > 0 ? :pos : :neg\n  end\n  NEG = f(-1)\nend\n")
      path = write_inputs(dir, { "inputs" => [[1]] })
      stdout, stderr, status = run_cli("explore", target, "Early.f", "--strategy", "inputs", "--random", "0", "--inputs", path)
      assert status.success?, stderr
      assert_includes stdout, "covered: 1 of "
    end
  end

  # A library's entry file needs no --require for --require-by-name, a
  # method of a private constant is reached through const_get, and a
  # message over several lines is pinned as it was raised, so the emitted
  # tests pass on the code they came from.
  def test_emitted_tests_pass_for_a_private_constant_with_a_multiline_message
    Dir.mktmpdir do |dir|
      lib = File.join(dir, "lib")
      FileUtils.mkdir_p(lib)
      target = File.join(lib, "agree.rb")
      File.write(target, <<~RUBY)
        module Agree
          module Check
            def self.check!(n)
              raise ArgumentError, "differs\\n  n: \#{n}" if n.positive?

              n
            end
          end
          private_constant :Check
        end
      RUBY
      path = write_inputs(dir, { "inputs" => [[1], [0]] })
      %w[agree_test.rb agree_spec.rb].each do |name|
        out = File.join(dir, name)
        _out, err, status = run_cli("explore", target, "Agree::Check.check!", "--strategy", "inputs", "--random", "0",
                                    "--inputs", path, "--emit-tests", out, "--require-by-name")
        assert status.success?, err
        source = File.read(out)
        assert_includes source, "require \"agree\"\n"
        assert_includes source, "Agree.const_get(:Check).check!(1)"
        assert_includes source, '"differs\n  n: 1"'
        command = name.end_with?("_spec.rb") ? [RbConfig.ruby, "-I", lib, "-rrspec/autorun", "-e", "", out] : [RbConfig.ruby, "-I", lib, out]
        output, err, status = Open3.capture3(*command)
        assert status.success?, "#{source}\n#{output}\n#{err}"
      end
    end
  end

  # An input's own pin_keys replace --pin-keys for that input alone, so
  # one inputs file can pin a whole Hash for one call and two keys for
  # another.
  def test_an_input_names_its_own_pin_keys
    Dir.mktmpdir do |dir|
      target = File.join(dir, "receipt.rb")
      File.write(target, "module Receipt\n  def self.build(n)\n    { total: n * 2, tax: n > 2 ? 1 : 0, id: \"r\" }\n  end\nend\n")
      path = write_inputs(dir, { "inputs" => [[1], { "args" => [3], "pin_keys" => ["tax"] }, { "args" => [5], "pin_keys" => [] }] })
      test = File.join(dir, "receipt_test.rb")
      spec = File.join(dir, "receipt_spec.rb")
      [test, spec].each do |out|
        _out, err, status = run_cli("explore", target, "Receipt.build", "--strategy", "inputs", "--random", "0",
                                    "--inputs", path, "--emit-tests", out, "--pin-keys", "total")
        assert status.success?, err
      end
      minitest = File.read(test)
      assert_includes minitest, "    assert_equal({ total: 2 }, Receipt.build(1).slice(:total))\n"
      assert_includes minitest, "    assert_equal({ tax: 1 }, Receipt.build(3).slice(:tax))\n"
      assert_includes minitest, "    assert_equal({ total: 10, tax: 1, id: \"r\" }, Receipt.build(5))\n"
      rspec = File.read(spec)
      assert_includes rspec, "      expect(described_class.build(1)).to include({ total: 2 })\n"
      assert_includes rspec, "      expect(described_class.build(3)).to include({ tax: 1 })\n"
      assert_includes rspec, "      expect(described_class.build(5)).to eq({ total: 10, tax: 1, id: \"r\" })\n"

      write_inputs(dir, { "inputs" => [{ "args" => [1], "pin_keys" => "tax" }] })
      _out, err, status = run_cli("explore", target, "Receipt.build", "--strategy", "inputs", "--random", "0", "--inputs", path)
      refute status.success?
      assert_equal "branchout: #{path} inputs[0] pin_keys must be an array of key names\n", err
    end
  end

  # --pin-keys pins chosen keys of a returned Hash, so a key added later
  # fails no test.
  def test_pin_keys_pins_only_the_chosen_keys_of_a_hash
    Dir.mktmpdir do |dir|
      target = File.join(dir, "receipt.rb")
      File.write(target, "module Receipt\n  def self.build(n)\n    { total: n * 2, tax: n > 2 ? 1 : 0, id: \"r\" }\n  end\nend\n")
      path = write_inputs(dir, { "inputs" => [[1], [3]] })
      test = File.join(dir, "receipt_test.rb")
      spec = File.join(dir, "receipt_spec.rb")
      [test, spec].each do |out|
        _out, err, status = run_cli("explore", target, "Receipt.build", "--strategy", "inputs", "--random", "0",
                                    "--inputs", path, "--emit-tests", out, "--pin-keys", "total,tax,missing")
        assert status.success?, err
      end
      assert_includes File.read(test), "    assert_equal({ total: 6, tax: 1 }, Receipt.build(3).slice(:total, :tax))\n"
      assert_includes File.read(test), "  def test_3_returns_total_6\n"
      assert_includes File.read(spec), "      expect(described_class.build(3)).to include({ total: 6, tax: 1 })\n"
      File.write(target, "module Receipt\n  def self.build(n)\n    { total: n * 2, tax: n > 2 ? 1 : 0, id: \"r\", note: nil }\n  end\nend\n")
      _out, err, status = Open3.capture3(RbConfig.ruby, test)
      assert status.success?, err
      _out, err, status = Open3.capture3(RbConfig.ruby, "-rrspec/autorun", "-e", "", spec)
      assert status.success?, err
    end
  end

  # An RSpec example pins an Array of Structs whose members have literals
  # by value, so a changed member fails it.
  def test_rspec_pins_the_members_of_structs_in_an_array
    Dir.mktmpdir do |dir|
      target = File.join(dir, "rules.rb")
      source = "require \"set\"\nmodule Rules\n  Rule = Struct.new(:action, :args, :tags)\n" \
               "  def self.list(n) = Array.new(n) { |i| Rule.new(\"a\#{i}\", [i], Set[i]) }\nend\n"
      File.write(target, source)
      path = write_inputs(dir, { "inputs" => [[2]] })
      spec = File.join(dir, "rules_spec.rb")
      _out, err, status = run_cli("explore", target, "Rules.list", "--strategy", "inputs", "--random", "0",
                                  "--inputs", path, "--emit-tests", spec)
      assert status.success?, err
      text = File.read(spec)
      assert_includes text, "    it \"returns an Array of 2\" do\n"
      assert_includes text, "expect(described_class.list(2)).to eq([Rules::Rule.new(action: \"a0\", args: [0], tags: Set[0]), " \
                            "Rules::Rule.new(action: \"a1\", args: [1], tags: Set[1])])\n"
      _out, err, status = Open3.capture3(RbConfig.ruby, "-rrspec/autorun", "-e", "", spec)
      assert status.success?, err
      File.write(target, source.sub("[i]", "[i + 1]"))
      out, _err, status = Open3.capture3(RbConfig.ruby, "-rrspec/autorun", "-e", "", spec)
      refute status.success?, out
    end
  end

  # With --require-by-name the emitted test loads the library from the load
  # path, so it tests whichever checkout -I names: jitcatch runs it in a base
  # and a head worktree.
  def test_emitted_tests_can_require_the_library_by_name
    Dir.mktmpdir do |dir|
      lib = File.join(dir, "repo/lib")
      FileUtils.mkdir_p(File.join(lib, "shop"))
      File.write(File.join(lib, "shop.rb"), "require_relative \"shop/cart\"\n")
      File.write(File.join(lib, "shop/cart.rb"), "module Shop\n  def self.size(n) = n > 2 ? :big : :small\nend\n")
      path = write_inputs(dir, { "inputs" => [[2], [3]] })
      %w[cart_test.rb cart_spec.rb].each do |name|
        test = File.join(dir, "out", name)
        _out, err, status = run_cli(
          "explore", File.join(lib, "shop/cart.rb"), "Shop.size", "--require", File.join(lib, "shop.rb"),
          "--strategy", "inputs", "--random", "0", "--inputs", path, "--emit-tests", test, "--require-by-name"
        )
        assert status.success?, err
        assert_includes File.read(test), "\nrequire \"shop\"\n\n"
        refute_includes File.read(test), "require_relative"
      end

      copy = File.join(dir, "head/lib")
      FileUtils.mkdir_p(File.dirname(copy))
      FileUtils.cp_r(lib, copy)
      File.write(File.join(copy, "shop/cart.rb"), "module Shop\n  def self.size(n) = n > 1 ? :big : :small\nend\n")
      test = File.join(dir, "out/cart_test.rb")
      _out, err, status = Open3.capture3(RbConfig.ruby, "-I", lib, test)
      assert status.success?, err
      out, _err, status = Open3.capture3(RbConfig.ruby, "-I", copy, test)
      refute status.success?, out
    end
  end

  # A --require that names no file is a feature on the -I directories or
  # the load path, as Ruby's own -r reads it.
  def test_a_require_that_names_no_file_is_found_on_the_load_path
    Dir.mktmpdir do |dir|
      lib = File.join(dir, "lib")
      FileUtils.mkdir_p(File.join(lib, "shop"))
      File.write(File.join(lib, "shop.rb"), "require_relative \"shop/cart\"\n")
      File.write(File.join(lib, "shop/cart.rb"), "module Shop\n  def self.size(n) = n > 2 ? :big : :small\nend\n")
      path = write_inputs(dir, { "inputs" => [[2], [3]] })
      test = File.join(dir, "out/cart_test.rb")
      out, err, status = run_cli("explore", File.join(lib, "shop/cart.rb"), "Shop.size", "-I", lib, "--require", "shop",
                                 "--strategy", "inputs", "--random", "0", "--inputs", path, "--emit-tests", test, "--require-by-name")
      assert status.success?, err
      assert_includes out, "covered: 2 of 2 arms by "
      assert_includes File.read(test), "\nrequire \"shop\"\n\n"

      _out, err, status = run_cli("explore", File.join(lib, "shop/cart.rb"), "Shop.size", "-I", lib, "--require", "shop",
                                  "--require", "etc", "--strategy", "inputs", "--random", "0", "--inputs", path)
      assert status.success?, err

      _out, err, status = run_cli("explore", File.join(lib, "shop/cart.rb"), "Shop.size", "-I", lib, "--require", "shopp")
      refute status.success?
      assert_equal "branchout: --require shopp names no file under the working directory, an -I directory, or the load path\n", err
    end
  end

  # A require_relative out of the emitted test's project names this
  # machine's directories, whether it is absolute or climbs into another
  # project, so stderr says the test runs only here.
  def test_a_test_that_requires_a_file_outside_its_project_by_path_is_warned_about
    Dir.mktmpdir do |dir|
      app = File.join(dir, "app")
      FileUtils.mkdir_p(File.join(app, "lib"))
      File.write(File.join(app, "Gemfile"), "")
      FileUtils.cp(File.join(ROOT, "test/fixtures/magic.rb"), File.join(app, "lib/magic.rb"))
      other = File.join(dir, "other")
      FileUtils.mkdir_p(other)
      File.write(File.join(other, "Gemfile"), "")
      path = write_inputs(dir, { "inputs" => [[0]] })
      args = ["explore", File.join(app, "lib/magic.rb"), "FixtureMagic.classify", "--strategy", "inputs", "--random", "0", "--inputs", path]

      _out, err, status = run_cli(*args, "--emit-tests", File.join(app, "test/magic_test.rb"))
      assert status.success?, err
      assert_equal "", err

      test = File.join(other, "test/magic_test.rb")
      _out, err, status = run_cli(*args, "--emit-tests", test)
      assert status.success?, err
      assert_includes File.read(test), "require_relative \"../../app/lib/magic.rb\"\n"
      assert_equal "branchout: the emitted test requires #{File.join(app, "lib/magic.rb")} by its path, outside the test's project, " \
                   "so the test runs only where that file sits on this machine. Emit the test under that file's project, " \
                   "or pass --require-by-name to require it through the load path.\n", err
    end
  end

  # A Rails model is outside lib: -I puts its directory on the load path,
  # for the explore run and for the name the emitted test requires.
  def test_a_load_path_directory_names_a_target_outside_lib
    Dir.mktmpdir do |dir|
      repo = File.join(dir, "repo")
      FileUtils.mkdir_p(File.join(repo, "lib"))
      FileUtils.mkdir_p(File.join(repo, "app/models"))
      File.write(File.join(repo, "Gemfile"), "")
      File.write(File.join(repo, "lib/shop.rb"), "module Shop\n  LIMIT = 2\nend\n")
      File.write(File.join(repo, "app/models/sizing.rb"), "module Sizing\n  def self.big?(n) = n > Shop::LIMIT\nend\n")
      File.write(File.join(repo, "app/models/cart.rb"), "require \"sizing\"\n\nmodule Cart\n  def self.size(n) = Sizing.big?(n) ? :big : :small\nend\n")
      path = write_inputs(dir, { "inputs" => [[2], [3]] })
      test = File.join(dir, "out/cart_test.rb")
      args = ["explore", File.join(repo, "app/models/cart.rb"), "Cart.size", "--require", File.join(repo, "lib/shop.rb"),
              "--strategy", "inputs", "--random", "0", "--inputs", path, "--emit-tests", test, "--require-by-name"]
      _out, err, status = run_cli(*args, "-I", File.join(repo, "app/models"))
      assert status.success?, err
      assert_equal "", err
      assert_includes File.read(test), "\n# Load path: -I lib (in repo) -I app/models (in repo)\nrequire \"shop\"\nrequire \"cart\"\n"
      _out, err, status = Open3.capture3(RbConfig.ruby, "-I", File.join(repo, "lib"), "-I", File.join(repo, "app/models"), test)
      assert status.success?, err

      _out, err, status = run_cli(*args)
      refute status.success?
      assert_includes err, "cannot load such file -- sizing"
      File.write(File.join(repo, "app/models/plain.rb"), "module Plain\n  def self.size(n) = n > Shop::LIMIT ? :big : :small\nend\n")
      args[1, 2] = [File.join(repo, "app/models/plain.rb"), "Plain.size"]
      _out, err, status = run_cli(*args)
      assert status.success?, err
      # The test sits outside the repository, so one warning says both.
      assert_equal "branchout: the emitted test requires #{File.join(repo, "app/models/plain.rb")} by its path, outside the test's project, " \
                   "so the test runs only where that file sits on this machine. Emit the test under that file's project, " \
                   "or pass -I with a directory that holds it to require it through the load path.\n", err
      assert_includes File.read(test), "# Required by path: no -I or --require directory holds "
      args[args.index(test)] = File.join(repo, "test/plain_test.rb")
      _out, err, status = run_cli(*args)
      assert status.success?, err
      assert_match %r{\Abranchout: \S*app/models/plain\.rb is under no -I or --require directory, so the emitted test requires it by path\.\s\S+[^\n]*\n\z}, err
    end
  end

  # A record, an exception, or a block has no JSON form, so an input names
  # the Ruby that builds it, such as a factory in a --require file; the
  # emitted tests write that Ruby as it was given.
  def test_an_input_builds_an_object_and_a_block_from_ruby_it_names
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "factories.rb"), "Loan = Struct.new(:amount)\n\nmodule Factories\n  def self.loan(amount) = Loan.new(amount)\nend\n")
      File.write(File.join(dir, "lending.rb"), <<~RUBY)
        module Lending
          def self.approve(loan, &rule)
            return :failed if loan.is_a?(StandardError)

            rule.call(loan.amount) ? :ok : :refused
          end
        end
      RUBY
      path = write_inputs(dir, { "inputs" => [
        { "args" => [{ "ruby" => "Factories.loan(3)" }], "block" => "{ |amount| amount > 2 }" },
        { "args" => [{ "ruby" => "Factories.loan(1)" }], "block" => "{ |amount| amount > 2 }" },
        { "args" => [{ "ruby" => "KeyError.new(\"sku\")" }] }
      ] })
      args = ["explore", File.join(dir, "lending.rb"), "Lending.approve", "--require", File.join(dir, "factories.rb"),
              "--strategy", "inputs", "--random", "0", "--inputs", path]
      out, err, status = run_cli(*args)
      assert status.success?, err
      assert_includes out, "covered: 4 of "
      refute_includes out, "EXCEPTIONS\n  -"
      %w[lending_test.rb lending_spec.rb].each do |name|
        test = File.join(dir, name)
        _out, err, status = run_cli(*args, "--emit-tests", test)
        assert status.success?, err
        lending = name.end_with?("_spec.rb") ? "described_class" : "Lending"
        assert_includes File.read(test), "#{lending}.approve(Factories.loan(3)) { |amount| amount > 2 }"
        assert_includes File.read(test), "#{lending}.approve(KeyError.new(\"sku\"))"
      end
      _out, err, status = Open3.capture3(RbConfig.ruby, File.join(dir, "lending_test.rb"))
      assert status.success?, err
      spec = File.read(File.join(dir, "lending_spec.rb"))
      assert_includes spec, "when loan is Factories.loan(3)"
      _out, err, status = Open3.capture3(RbConfig.ruby, "-rrspec/autorun", "-e", "", File.join(dir, "lending_spec.rb"))
      assert status.success?, err
    end
  end

  def test_an_input_whose_ruby_does_not_parse_is_refused
    Dir.mktmpdir do |dir|
      path = write_inputs(dir, { "inputs" => [{ "args" => [{ "ruby" => "Loan.new(" }] }] })
      _out, err, status = run_cli("explore", "test/fixtures/scale.rb", "FixtureScale.scale", "--inputs", path)
      refute status.success?
      assert_match(/\Abranchout: .*inputs\[0\] Ruby "Loan.new\(" does not parse/, err)
      path = write_inputs(dir, { "inputs" => [{ "args" => [1], "block" => "x + 1" }] })
      _out, err, status = run_cli("explore", "test/fixtures/scale.rb", "FixtureScale.scale", "--inputs", path)
      refute status.success?
      assert_match(/\Abranchout: .*inputs\[0\] block "x \+ 1" is not a block such as/, err)
    end
  end

  # jitcatch copies a test under .jitcatch/ to the root of each checkout,
  # and its rerun line loads the test where it was written. Only a require
  # through the load path names the same checkout from both places.
  def test_a_test_under_jitcatch_requires_the_target_by_name
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "lib"))
      target = File.join(dir, "lib/scale.rb")
      FileUtils.cp(File.join(ROOT, "test/fixtures/scale.rb"), target)
      path = write_inputs(dir, { "inputs" => [[1]] })
      { ".jitcatch/scale_test.rb" => "require \"scale\"\n", "candidates/scale_test.rb" => "require_relative \"../lib/scale.rb\"\n" }.each do |name, line|
        out = File.join(dir, name)
        _out, err, status = run_cli("explore", target, "FixtureScale.scale", "--strategy", "inputs", "--random", "0",
                                    "--inputs", path, "--emit-tests", out)
        assert status.success?, err
        assert_includes File.read(out), line
      end
    end
  end

  # A path under the test's project is written from the test's own file,
  # so the test passes in a copy of the project on another machine. A
  # file of this machine outside the project stays a literal, and stderr
  # says which input names it.
  def test_an_input_path_under_the_project_is_written_from_the_test_file
    Dir.mktmpdir do |dir|
      app = File.join(dir, "app")
      FileUtils.mkdir_p(File.join(app, "lib"))
      FileUtils.mkdir_p(File.join(app, "spec/fixtures"))
      File.write(File.join(app, "Gemfile"), "")
      File.write(File.join(app, "spec/fixtures/rates.csv"), "3\n")
      File.write(File.join(app, "lib/sheet.rb"), <<~RUBY)
        module Sheet
          def self.rate(path) = File.exist?(path) ? File.read(path).to_i : :missing
        end
      RUBY
      outside = File.join(dir, "elsewhere.csv")
      File.write(outside, "4\n")
      missing = File.join(dir, "gone/rates.csv")
      paths = [File.join(app, "spec/fixtures/rates.csv"), File.join(app, "spec/fixtures/none.csv"), outside, missing]
      inputs = write_inputs(dir, { "inputs" => paths.map { |path| [path] } })
      %w[spec/sheet_test.rb spec/sheet_spec.rb].each do |name|
        out = File.join(app, name)
        _out, err, status = run_cli("explore", File.join(app, "lib/sheet.rb"), "Sheet.rate", "--strategy", "inputs", "--random", "0",
                                    "--inputs", inputs, "--emit-tests", out)
        assert status.success?, err
        source = File.read(out)
        sheet = name.end_with?("_spec.rb") ? "described_class" : "Sheet"
        assert_includes source, %(#{sheet}.rate(File.expand_path("fixtures/rates.csv", __dir__)))
        assert_includes source, %(#{sheet}.rate(File.expand_path("fixtures/none.csv", __dir__)))
        assert_includes source, "#{sheet}.rate(#{outside.inspect})"
        refute_includes source, app
        assert_equal "branchout: the emitted test passes #{outside}, a file of this machine outside the test's project, so the " \
                     "test passes only here. Put the file under the project, and the test names it from its own directory.\n" \
                     "branchout: the emitted test passes #{missing}, a path of this machine outside the test's project that does " \
                     "not exist, so the test holds this machine's directories. Put the path under the project, and the test " \
                     "names it from its own directory.\n", err
      end

      moved = File.join(dir, "moved")
      FileUtils.mv(app, moved)
      %w[sheet_test.rb sheet_spec.rb].each do |name|
        out = File.join(moved, "spec", name)
        command = name.end_with?("_spec.rb") ? [RbConfig.ruby, "-rrspec/autorun", "-e", "", out] : [RbConfig.ruby, out]
        output, err, status = Open3.capture3(*command)
        assert status.success?, "#{File.read(out)}\n#{output}\n#{err}"
      end
    end
  end

  # A returned value or an error message that holds a path under the
  # project names the project from the test's own file. A path of this
  # machine outside the project stays a literal, stderr says so, and the
  # test's names keep only its file, so they are the same on every machine.
  def test_a_returned_path_or_message_under_the_project_is_written_from_the_test_file
    Dir.mktmpdir do |dir|
      app = File.join(dir, "app")
      FileUtils.mkdir_p(File.join(app, "lib"))
      FileUtils.mkdir_p(File.join(app, "spec/fixtures"))
      File.write(File.join(app, "Gemfile"), "")
      File.write(File.join(app, "spec/fixtures/rates.csv"), "3\n")
      File.write(File.join(app, "lib/sheet.rb"), <<~RUBY)
        module Sheet
          def self.read(path) = path.end_with?(".csv") ? [File.expand_path(path), File.read(path)] : :other
        end
      RUBY
      outside = File.join(dir, "nothing.csv")
      paths = [File.join(app, "spec/fixtures/rates.csv"), File.join(app, "spec/fixtures/none.csv"), outside]
      inputs = write_inputs(dir, { "inputs" => paths.map { |path| [path] } })
      %w[spec/sheet_test.rb spec/sheet_spec.rb].each do |name|
        out = File.join(app, name)
        _out, err, status = run_cli("explore", File.join(app, "lib/sheet.rb"), "Sheet.read", "--strategy", "inputs", "--random", "0",
                                    "--inputs", inputs, "--emit-tests", out)
        assert status.success?, err
        source = File.read(out)
        assert_includes source, %q[[File.expand_path("fixtures/rates.csv", __dir__), "3\n"]]
        assert_includes source, %q["No such file or directory @ rb_sysopen - #{File.expand_path("..", __dir__)}/spec/fixtures/none.csv"]
        refute_includes source, app
        assert_equal "branchout: the emitted test pins #{outside}, a path of this machine outside the test's project, in a returned " \
                     "value or an error message, so the test passes only here. Give Sheet.read a path under the project.\n", err
        next if name.end_with?("_spec.rb")

        assert_equal %w[test_nothing_csv_raises_errno_enoent test_spec_fixtures_none_csv_raises_errno_enoent
                        test_spec_fixtures_rates_csv_returns_array_spec_fixtures], source.scan(/def (test_\w+)/).flatten.sort
      end

      moved = File.join(dir, "moved")
      FileUtils.mv(app, moved)
      %w[sheet_test.rb sheet_spec.rb].each do |name|
        out = File.join(moved, "spec", name)
        command = name.end_with?("_spec.rb") ? [RbConfig.ruby, "-rrspec/autorun", "-e", "", out] : [RbConfig.ruby, out]
        output, err, status = Open3.capture3(*command)
        assert status.success?, "#{File.read(out)}\n#{output}\n#{err}"
      end
    end
  end

  def test_require_by_name_needs_emitted_tests
    Dir.mktmpdir do |dir|
      path = write_inputs(dir, { "inputs" => [[1]] })
      base = ["explore", "test/fixtures/scale.rb", "FixtureScale.scale", "--inputs", path, "--require-by-name"]
      _out, err, status = run_cli(*base, "--require", "test/fixtures/helpers.rb")
      refute status.success?
      assert_equal "branchout: --require-by-name requires --emit-tests\n", err
    end
  end

  # Only a file that opens the Branchout namespace is a copy. A project file
  # that shares a path with one of branchout's own files is not.
  def test_a_project_file_named_like_a_branchout_file_is_explored
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "lib/branchout"))
      File.write(File.join(dir, "lib/branchout.rb"), "require \"branchout/report\"\n")
      File.write(File.join(dir, "lib/branchout/report.rb"), "module Shop\n  def self.f(x) = x > 0 ? :pos : :neg\nend\n")
      path = write_inputs(dir, { "inputs" => [[1]] })
      stdout, stderr, status = run_cli(
        "explore", File.join(dir, "lib/branchout/report.rb"), "Shop.f",
        "--require", File.join(dir, "lib/branchout.rb"), "--strategy", "inputs", "--random", "0", "--inputs", path
      )
      assert status.success?, stderr
      assert_includes stdout, "covered: 1 of "
    end
  end

  # A file of the running branchout was loaded before coverage started, so
  # it is loaded again to be measured.
  def test_branchout_explores_its_own_files
    Dir.mktmpdir do |dir|
      path = write_inputs(dir, { "inputs" => [["a"], ["a b"]] })
      stdout, stderr, status = run_cli(
        "explore", "lib/branchout/emitters/support.rb", "Branchout::Emitters::Support.keyword_literal",
        "--strategy", "inputs", "--random", "0", "--inputs", path
      )
      assert status.success?, stderr
      assert_includes stdout, "covered: 2 of 2 arms by "
      assert_empty stderr
    end
  end

  # The tool built the receiver's Code before the target ran. Loading the
  # target's file again would define Branchout::Code a second time, and the
  # tool's Code would no longer be one.
  def test_a_receiver_built_by_ruby_reaches_a_target_among_branchout_files
    Dir.mktmpdir do |dir|
      path = write_inputs(dir, { "inputs" => [{ "receiver" => { "ruby" => "Branchout::Input.new(args: [1])" }, "args" => [] }] })
      stdout, stderr, status = run_cli(
        "explore", "lib/branchout/input.rb", "Branchout::Input#text",
        "--strategy", "inputs", "--random", "0", "--inputs", path, "--json"
      )
      assert status.success?, stderr
      report = JSON.parse(stdout)
      assert_equal [], report["exceptions"]
      assert_equal 1, report["arms_covered"]
      assert_empty stderr
    end
  end

  # Rails loads an initializer with Kernel#load, which leaves it out of
  # $LOADED_FEATURES. Coverage counts it already, so it is not loaded again.
  def test_a_target_a_require_file_loaded_with_load_runs_once
    Dir.mktmpdir do |dir|
      target = File.join(dir, "t.rb")
      File.write(target, "$t_loads = ($t_loads || 0) + 1\nclass T\n  def self.f(x) = x ? $t_loads : 0\nend\n")
      env = File.join(dir, "env.rb")
      File.write(env, "load #{target.dump}\n")
      path = write_inputs(dir, { "inputs" => [[true]] })
      stdout, stderr, status = run_cli("explore", target, "T.f", "--require", env, "--strategy", "inputs", "--random", "0",
                                       "--inputs", path, "--emit-tests", File.join(dir, "t_test.rb"))
      assert status.success?, stderr
      assert_includes stdout, "covered: 1 of 2 arms by "
      assert_includes File.read(File.join(dir, "t_test.rb")), "assert_equal 1, T.f(true)"
    end
  end

  # A file that loaded with the tool, before coverage was set up, has no
  # arms, and loading it again would define its classes a second time.
  def test_a_target_loaded_before_coverage_is_refused
    loaded = $LOADED_FEATURES.find { |file| file.end_with?("/did_you_mean/jaro_winkler.rb") }
    _stdout, stderr, status = run_cli("explore", loaded, "DidYouMean::JaroWinkler.distance", "--strategy", "inputs", "--random", "0")
    refute status.success?
    assert_equal "branchout: #{loaded} loaded before explore set up coverage, so Coverage has no arms for it, " \
                 "and loading it again would define its classes a second time.\n", stderr
  end

  # A superclass or constant from another file is a NameError at load time.
  # The run stops with one line that names it and the flag that fixes it.
  def test_a_constant_missing_at_load_time_suggests_require
    Dir.mktmpdir do |dir|
      target = File.join(dir, "child.rb")
      File.write(target, "class Child < Parent\n  def f = 1\nend\n")
      _stdout, stderr, status = run_cli("explore", target, "Child#f", "--strategy", "inputs", "--random", "0")
      refute status.success?
      assert_equal "branchout: failed to load #{target}: uninitialized constant Parent (NameError). " \
                   "Pass the file that defines Parent with --require.\n", stderr
    end
  end

  # A Rails app's environment raises when a setting is missing. The run
  # stops with one line that names the file that raised and where.
  def test_an_error_raised_while_a_require_file_loads_is_one_line
    Dir.mktmpdir do |dir|
      env = File.join(dir, "env.rb")
      File.write(env, "x = 1\nraise \"DATABASE_URL is not set\\nsee config\" if x\n")
      target = File.join(dir, "t.rb")
      File.write(target, "class T\n  def self.f(x) = x ? 1 : 2\nend\n")
      _stdout, stderr, status = run_cli("explore", target, "T.f", "--require", env, "--strategy", "inputs", "--random", "0")
      refute status.success?
      assert_equal "branchout: failed to load #{env}: DATABASE_URL is not set (RuntimeError at #{env}:2)\n", stderr

      File.write(env, "ENV_LOADED = true\n")
      File.write(target, "raise ArgumentError, \"no rate\" if ENV_LOADED\nclass T\n  def self.f(x) = x ? 1 : 2\nend\n")
      _stdout, stderr, status = run_cli("explore", target, "T.f", "--require", env, "--strategy", "inputs", "--random", "0")
      refute status.success?
      assert_equal "branchout: failed to load #{target}: no rate (ArgumentError at #{target}:1)\n", stderr
    end
  end

  # A check that moves from the entry into a parent class in another file
  # takes its arms out of arms_total. The report names that callee and how
  # many arms it has, so a smaller total does not read as less logic. An
  # attribute reader, or a method with no arms, hides no arm, so it is not
  # named.
  def test_the_report_names_callees_in_other_files_it_did_not_count
    Dir.mktmpdir do |dir|
      parent = File.join(dir, "parent.rb")
      child = File.join(dir, "child.rb")
      File.write(parent, <<~RUBY)
        class Parent
          private

          def checked(text)
            raise ArgumentError, "blank" if text.empty?

            text
          end

          def plain(text) = text

          attr_reader :tag
        end
      RUBY
      File.write(child, <<~RUBY)
        class Child < Parent
          def label(text)
            name = plain(checked(text)) + tag.to_s
            short?(name) ? :short : :long
          end

          private

          def short?(name) = name.length < 3 ? true : false
        end
      RUBY
      path = write_inputs(dir, { "inputs" => [["ab"]] })
      args = ["explore", "--verbose", child, "Child#label", "--require", parent, "--strategy", "inputs", "--random", "0", "--inputs", path]
      stdout, stderr, status = run_cli(*args)
      assert status.success?, stderr
      assert_includes stdout, "arms_total: 4\nexceptions: 0\ncallees_not_counted: 1\n"
      assert stdout.end_with?(<<~TEXT), stdout
        NOT COUNTED
        callee: Parent#checked
        loc: #{parent}:4
        arms: 2

        OPERATORS
        (none)

        BOUNDARIES
        loc: #{child}:9:33
        op: <
        text: name.length < 3
      TEXT

      stdout, stderr, status = run_cli(*(args - ["--verbose"]), "--json")
      assert status.success?, stderr
      assert_equal [
        { "callee" => "Parent#checked", "loc" => "#{parent}:4", "arms" => 2 }
      ], JSON.parse(stdout)["not_counted"]

      stdout, = run_cli(*(args - ["--verbose"]))
      assert_includes stdout, "\nNOT COUNTED (arms in other files; explore each as its own entry)\nParent#checked at #{parent}:4 (2 arms)\n"
    end
  end

  # A mixin with no name has no stable text, since its inspect carries an
  # address, so the report names it by the class it is mixed into.
  def test_a_callee_of_an_anonymous_module_has_a_stable_name
    Dir.mktmpdir do |dir|
      helpers = File.join(dir, "helpers.rb")
      File.write(helpers, "$helpers = Module.new do\n  def checked(x) = x.positive? ? x : 0\nend\n")
      child = File.join(dir, "child.rb")
      File.write(child, "class Child\n  include $helpers\n  extend $helpers\n\n  def self.build(x) = checked(x)\n  def size(x) = checked(x) > 2 ? :big : :small\nend\n")
      path = write_inputs(dir, { "inputs" => [[1]] })
      { "Child#size" => "Child (an anonymous module)#checked", "Child.build" => "Child (an anonymous module).checked" }.each do |entry, name|
        stdout, stderr, status = run_cli("explore", child, entry, "--require", helpers, "--strategy", "inputs", "--random", "0",
                                         "--inputs", path, "--json")
        assert status.success?, stderr
        assert_equal [{ "callee" => name, "loc" => "#{helpers}:2", "arms" => 2 }], JSON.parse(stdout)["not_counted"]
      end
    end
  end

  # A service object the entry builds with Const.new, kept in a local or
  # in an instance variable, runs logic the report does not count, so the
  # report names its methods. A call on an untyped value is not named.
  def test_the_report_names_methods_called_on_objects_the_class_builds
    Dir.mktmpdir do |dir|
      ledger = File.join(dir, "ledger.rb")
      File.write(ledger, <<~RUBY)
        module Shop
          class Ledger
            def post(amount) = amount.negative? ? :refund : :sale
            def audit(amount) = amount > 100 ? :review : :ok
            def close = :closed
          end
        end
      RUBY
      till = File.join(dir, "till.rb")
      File.write(till, <<~RUBY)
        module Shop
          class Till
            def initialize
              @ledger = Ledger.new
            end

            def ring(amount, other)
              journal = Shop::Ledger.new
              other.post(amount)
              @ledger.post(amount) == :sale && journal.audit(amount) == :ok ? :done : :held
            end
          end
        end
      RUBY
      path = write_inputs(dir, { "inputs" => [[5, 1]] })
      stdout, stderr, status = run_cli("explore", till, "Shop::Till#ring", "--require", ledger, "--strategy", "inputs", "--random", "0",
                                       "--inputs", path, "--json")
      assert status.success?, stderr
      assert_equal [
        { "callee" => "Shop::Ledger#post", "loc" => "#{ledger}:3", "arms" => 2 },
        { "callee" => "Shop::Ledger#audit", "loc" => "#{ledger}:4", "arms" => 2 }
      ], JSON.parse(stdout)["not_counted"]
    end
  end

  # An app cannot move a check into a gem, and a Rails model calls dozens
  # of gem methods (an association reader, update!), so a callee whose file
  # is in an installed gem is not named.
  def test_not_counted_leaves_out_methods_of_installed_gems
    Dir.mktmpdir do |dir|
      shown = File.join(dir, "shown.rb")
      File.write(shown, <<~RUBY)
        require "minitest"

        class Shown
          include Minitest::Assertions

          def show(x) = mu_pp(x).size > 3 ? :long : :short
        end
      RUBY
      path = write_inputs(dir, { "inputs" => [[1]] })
      stdout, stderr, status = run_cli("explore", shown, "Shown#show", "--strategy", "inputs", "--random", "0", "--inputs", path, "--json")
      assert status.success?, stderr
      assert_equal [], JSON.parse(stdout)["not_counted"]
    end
  end

  # A class method's callee is named with a dot. Ruby's own prelude
  # methods, methods the target file defines without def, and a name Ruby
  # cannot find are not callees in other files.
  def test_not_counted_names_class_methods_and_skips_what_is_not_another_file
    Dir.mktmpdir do |dir|
      parent = File.join(dir, "parent.rb")
      child = File.join(dir, "child.rb")
      File.write(parent, "class Parent\n  def self.checked(x) = x.positive? ? x : 0\nend\n")
      File.write(child, <<~RUBY)
        class Child < Parent
          define_singleton_method(:local) { |x| x }

          def self.build(x)
            missing_thing if x == 99
            loop { break }
            local(checked(x))
          end
        end
      RUBY
      path = write_inputs(dir, { "inputs" => [[1]] })
      stdout, stderr, status = run_cli("explore", child, "Child.build", "--require", parent, "--strategy", "inputs", "--random", "0",
                                       "--inputs", path, "--json")
      assert status.success?, stderr
      assert_equal [{ "callee" => "Parent.checked", "loc" => "#{parent}:2", "arms" => 2 }], JSON.parse(stdout)["not_counted"]
    end
  end

  # Two inputs that are the same value run once. The person who wrote both
  # learns it, because inputs_ran alone does not say why it is lower.
  def test_a_repeated_input_runs_once_and_says_so
    Dir.mktmpdir do |dir|
      path = write_inputs(dir, { "inputs" => [[0], [114514], { "args" => [0] }, [0]] })
      stdout, stderr, status = run_cli(
        "explore", "--verbose", "test/fixtures/magic.rb", "FixtureMagic.classify",
        "--strategy", "inputs", "--random", "0", "--inputs", path
      )
      assert status.success?, stderr
      assert_includes stdout, "inputs_ran: 2"
      assert_equal "branchout: 2 of 4 inputs repeat an earlier input, so they did not run again.\n", stderr
    end
  end

  # A library's entry file often requires its siblings by load path, as
  # lib/name.rb does with require "name/part".
  def test_a_required_file_can_require_from_its_own_directory
    Dir.mktmpdir do |dir|
      path = write_inputs(dir, { "inputs" => [[[1]], [[1, 2]]] })
      stdout, stderr, status = run_cli(
        "explore", "test/fixtures/shelf/count.rb", "FixtureShelf.full?", "--require", "test/fixtures/shelf.rb",
        "--strategy", "inputs", "--random", "0", "--inputs", path
      )
      assert status.success?, stderr
      assert_includes stdout, "covered: 2 of "
    end
  end

  def test_division_is_recorded
    Dir.mktmpdir do |dir|
      path = write_inputs(dir, { "inputs" => [{ "args" => [24, 12] }] })
      stdout, stderr, status = run_cli(
        "explore", "--verbose", "test/fixtures/scale.rb", "FixtureScale.scale",
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
      "explore", "--verbose", "test/fixtures/scale.rb", "FixtureScale.scale",
      "--strategy", "mutate,random", "--seed", "1", "--random", "40"
    )
    assert status.success?, stderr
    assert_includes stdout, "EXCEPTIONS\n(none)"
  end

  def test_while_not_entered_is_a_reached_parent
    Dir.mktmpdir do |dir|
      path = write_inputs(dir, { "inputs" => [{ "args" => [0] }] })
      stdout, stderr, status = run_cli(
        "explore", "--verbose", "test/fixtures/spin.rb", "FixtureSpin.forever",
        "--strategy", "inputs", "--random", "0", "--inputs", path
      )
      assert status.success?, stderr
      assert_includes stdout, "parent: reached"
      assert_includes stdout, "nearest: [0]"
      assert_includes stdout, "path: (none)"
    end
  end

  # An input that timed out does not run a second time.
  def test_an_input_that_timed_out_runs_once
    Dir.mktmpdir do |dir|
      target = File.join(dir, "wait.rb")
      calls = File.join(dir, "calls")
      File.write(target, "module Wait\n  def self.on(path)\n    File.write(path, \"x\", mode: \"a\")\n    sleep\n  end\nend\n")
      _stdout, stderr, status = run_cli("explore", target, "Wait.on", "--strategy", "inputs", "--timeout", "0.1",
                                        "--inputs", write_inputs(dir, { "inputs" => [[calls]] }))
      assert status.success?, stderr
      assert_equal "x", File.read(calls)
    end
  end

  def test_timeout_is_a_finding
    Dir.mktmpdir do |dir|
      path = write_inputs(dir, { "inputs" => [{ "args" => [1] }] })
      stdout, stderr, status = run_cli(
        "explore", "--verbose", "test/fixtures/spin.rb", "FixtureSpin.forever",
        "--strategy", "inputs", "--random", "0", "--timeout", "0.2", "--inputs", path
      )
      assert status.success?, stderr
      assert_includes stdout, "class: Timeout::Error"
      assert_includes stdout, "message: execution expired"
      assert_includes stdout, "loc: test/fixtures/spin.rb:4"
    end
  end

  # An app's HTTP client raises a subclass of Timeout::Error, such as
  # Net::ReadTimeout, from a line of the target. It is not explore's own
  # timeout, so it keeps its class and the line that raised it.
  def test_a_timeout_the_target_raises_keeps_its_class_and_line
    Dir.mktmpdir do |dir|
      target = File.join(dir, "fetch.rb")
      File.write(target, <<~RUBY)
        require "timeout"

        class Fetch
          ReadTimeout = Class.new(Timeout::Error)

          def self.call(slow)
            return :ok unless slow

            raise ReadTimeout, "read timed out"
          end
        end
      RUBY
      path = write_inputs(dir, { "inputs" => [[true]] })
      stdout, stderr, status = run_cli("explore", "--verbose", target, "Fetch.call", "--strategy", "inputs", "--random", "0", "--inputs", path)
      assert status.success?, stderr
      assert_includes stdout, "class: Fetch::ReadTimeout\nloc: #{target}:9\n"
    end
  end

  # An input's Ruby that raises before the call says nothing about the
  # entry, so it is refused, not pinned.
  def test_an_error_raised_by_the_inputs_own_ruby_is_refused
    Dir.mktmpdir do |dir|
      path = write_inputs(dir, { "inputs" => [[{ "ruby" => "raise ArgumentError, 'no row'" }]] })
      stdout, stderr, status = run_cli(
        "explore", "--verbose", "test/fixtures/spin.rb", "FixtureSpin.forever",
        "--strategy", "inputs", "--random", "0", "--inputs", path
      )
      refute status.success?
      assert_equal "", stdout
      assert_equal "branchout: the input {\"args\":[{\"ruby\":\"raise ArgumentError, 'no row'\"}],\"kwargs\":{}} raised ArgumentError " \
                   "in its own Ruby before FixtureSpin.forever ran: no row. Fix the input.\n", stderr
    end
  end

  def test_case_condition_text
    Dir.mktmpdir do |dir|
      path = write_inputs(dir, { "inputs" => [{ "args" => ["a", 0] }] })
      stdout, stderr, status = run_cli(
        "explore", "--verbose", "test/fixtures/branches.rb", "FixtureBranches.demo",
        "--strategy", "inputs", "--random", "0", "--inputs", path
      )
      assert status.success?, stderr
      assert_includes stdout, 'cond: when "a", "b"'
    end
  end

  def test_instance_method
    stdout, stderr, status = run_cli(
      "explore", "--verbose", "test/fixtures/box.rb", "FixtureBox#parity",
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
        "explore", "--verbose", "test/fixtures/magic.rb", "FixtureMagic.classify",
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

  # Kernel#warn prints nothing under -W0, and an error or a no-branch
  # notice must still reach the person running the command.
  def test_errors_and_notices_print_under_w0
    Dir.mktmpdir do |dir|
      path = write_inputs(dir, { "inputs" => [[1]] })
      _stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-W0", BIN, "nope", chdir: ROOT)
      refute status.success?
      assert_equal "branchout: unknown command \"nope\"\n", stderr
      _stdout, stderr, status = Open3.capture3(
        RbConfig.ruby, "-W0", BIN, "explore", "test/fixtures/delegate.rb", "FixtureDelegate.forward",
        "--strategy", "inputs", "--random", "0", "--inputs", path, chdir: ROOT
      )
      assert status.success?
      assert_includes stderr, "have no branches"
    end
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
    %w[explore t.rb A.b --quiet] => "unknown option --quiet",
    %w[baselines t.rb A.b --verbose] => "--verbose is only valid with explore",
    %w[explore t.rb A.b --json --verbose] => "--verbose is only valid with the text report; --json holds every arm and the run settings",
    %w[explore t.rb A.b --format rspec] => "--format requires --emit-tests",
    %w[explore t.rb A.b --pin-keys a] => "--pin-keys requires --emit-tests",
    %w[explore t.rb A.b --emit-tests x.rb --pin-keys ,] => "--pin-keys list is empty",
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

  def test_the_target_output_load_time_calls_and_long_messages_stay_out_of_the_report
    Dir.mktmpdir do |dir|
      target = File.join(dir, "noisy.rb")
      File.write(target, <<~RUBY)
        class Noisy
          def initialize(scale = 1) = @scale = scale

          def self.f(x)
            puts "to stdout"
            warn "to stderr"
            raise ArgumentError, "z" * 300 if x > 9
            x > 5 ? :big : :small
          end

          def g(x) = x * @scale > 1 ? :big : :small
        end
        Noisy.f(7)
      RUBY
      path = write_inputs(dir, { "inputs" => [[0], [10]] })
      stdout, stderr, status = run_cli("explore", "--verbose", target, "Noisy.f", "--strategy", "inputs", "--random", "0", "--inputs", path)
      assert status.success?, stderr
      assert_empty stderr
      assert stdout.start_with?("branchout explore\n")
      refute_includes stdout, "to stdout"
      # The load-time call took the :big arm; only the inputs' arms count.
      assert_includes stdout, "FRONTIER\nid: if@8:4/then@8:12\n"
      assert_includes stdout, "message: #{"z" * 180}\n"

      path = write_inputs(dir, { "inputs" => [[2]] })
      stdout, stderr, status = run_cli("explore", "--verbose", target, "Noisy#g", "--strategy", "inputs", "--random", "0", "--inputs", path)
      assert status.success?, stderr
      assert_includes stdout, "arms_covered: 1"
    end
  end
end
