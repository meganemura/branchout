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
      callees_not_counted: 0

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
          "explore", "test/fixtures/cart.rb", "FixtureCart#volume_discount_cents",
          "--strategy", "inputs", "--random", "0", "--inputs", path, "--emit-tests", out
        )
        assert status.success?, stderr
      end
      # The setup's own call to size takes the empty arm; only the entry's
      # calls count, so that arm stays on the frontier.
      assert_includes stdout, "arms_covered: 4\narms_total: 6"
      assert_includes stdout, "id: if@28:4/then@28:20\nloc: test/fixtures/cart.rb:28:20\ncond: @items.empty?\nsense: cond-true\nparent: reached"
      assert_includes stdout, "class: ArgumentError\nloc: test/fixtures/cart.rb:10\n" \
                              'input: {"args":[],"kwargs":{},"setup":[{"args":["apple",0],"kwargs":{},"method":"add"}]}' \
                              "\nmessage: quantity must be positive"

      source = File.read(test)
      assert_includes source, "    fixture_cart = FixtureCart.new\n    fixture_cart.add(+\"apple\", 3)\n" \
                              "    assert_equal 100, fixture_cart.volume_discount_cents\n"
      assert_includes source, "    fixture_cart = FixtureCart.new(+\"EUR\")\n    fixture_cart.add(+\"apple\", 5)\n" \
                              "    fixture_cart.add(+\"pear\", 5, price: 50)\n" \
                              "    assert_equal 500, fixture_cart.volume_discount_cents\n"
      assert_includes source, "    error = assert_raises(ArgumentError) do\n      fixture_cart = FixtureCart.new\n" \
                              "      fixture_cart.add(+\"apple\", 0)\n      fixture_cart.volume_discount_cents\n    end\n"
      _out, err, status = Open3.capture3(RbConfig.ruby, test)
      assert status.success?, err
      # The input that raises keeps its setup inside the expect block, so
      # the raise is pinned wherever it comes from.
      assert_includes File.read(spec), "    context \"with new\" do\n      let(:fixture_cart) { FixtureCart.new }\n\n" \
                                       "      it 'raises ArgumentError after add(\"apple\", 0)' do\n        expect {\n" \
                                       "          fixture_cart.add(+\"apple\", 0)\n          volume_discount_cents\n" \
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

  def test_a_class_method_is_followed_through_new_to_the_instance_method
    Dir.mktmpdir do |dir|
      path = write_inputs(dir, { "inputs" => [[1], [-1]] })
      stdout, stderr, status = run_cli(
        "explore", "test/fixtures/delegate.rb", "FixtureDelegate.apply",
        "--strategy", "inputs", "--random", "0", "--inputs", path
      )
      assert status.success?, stderr
      assert_includes stdout, "arms_covered: 2\narms_total: 2"
      assert_empty stderr

      path = write_inputs(dir, { "inputs" => [["# a"], ["b"]] })
      stdout, stderr, status = run_cli(
        "explore", "test/fixtures/delegate.rb", "FixtureDocument.apply",
        "--strategy", "inputs", "--random", "0", "--inputs", path
      )
      assert status.success?, stderr
      assert_includes stdout, "arms_covered: 3\narms_total: 4"
      assert_includes stdout, "FRONTIER\nid: if@17:11/then@17:24\nloc: test/fixtures/delegate.rb:17:24\ncond: doc.empty?"
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
      assert_includes stdout, "arms_covered: 1\narms_total: 2"
      assert_includes stdout, "FRONTIER\nid: if@35:12/else@35:42"
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
          "explore", "test/fixtures/delegate.rb", entry,
          "--strategy", "inputs", "--random", "0", "--inputs", inputs
        )
        assert status.success?, stderr
        assert_includes stdout, "arms_total: 0\n", entry
      end
    end
  end

  def test_an_entry_with_no_arms_warns
    Dir.mktmpdir do |dir|
      path = write_inputs(dir, { "inputs" => [[1]] })
      stdout, stderr, status = run_cli(
        "explore", "test/fixtures/delegate.rb", "FixtureDelegate.forward",
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
        "explore", "test/fixtures/branches.rb", "FixtureBranches.demo",
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
      assert_includes stdout, "arms_covered: 1\n"
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
      assert_includes minitest, "    assert_equal({total: 2}, Receipt.build(1).slice(:total))\n"
      assert_includes minitest, "    assert_equal({tax: 1}, Receipt.build(3).slice(:tax))\n"
      assert_includes minitest, "    assert_equal({total: 10, tax: 1, id: \"r\"}, Receipt.build(5))\n"
      rspec = File.read(spec)
      assert_includes rspec, "      expect(Receipt.build(1)).to include({total: 2})\n"
      assert_includes rspec, "      expect(Receipt.build(3)).to include({tax: 1})\n"
      assert_includes rspec, "      expect(Receipt.build(5)).to eq({total: 10, tax: 1, id: \"r\"})\n"

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
      assert_includes File.read(test), "    assert_equal({total: 6, tax: 1}, Receipt.build(3).slice(:total, :tax))\n"
      assert_includes File.read(test), "  def test_3_returns__total_6\n"
      assert_includes File.read(spec), "      expect(Receipt.build(3)).to include({total: 6, tax: 1})\n"
      File.write(target, "module Receipt\n  def self.build(n)\n    { total: n * 2, tax: n > 2 ? 1 : 0, id: \"r\", note: nil }\n  end\nend\n")
      _out, err, status = Open3.capture3(RbConfig.ruby, test)
      assert status.success?, err
      _out, err, status = Open3.capture3(RbConfig.ruby, "-rrspec/autorun", "-e", "", spec)
      assert status.success?, err
    end
  end

  # An RSpec example pins an Array of Structs by its size and each
  # element's class and members, so a changed member fails it.
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
      assert_includes text, "expect(Rules.list(2)).to match([a_kind_of(Rules::Rule).and(have_attributes(action: \"a0\", args: [0], tags: a_kind_of(Set))), " \
                            "a_kind_of(Rules::Rule).and(have_attributes(action: \"a1\", args: [1], tags: a_kind_of(Set)))])\n"
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

  # A Rails model is outside lib: -I puts its directory on the load path,
  # for the explore run and for the name the emitted test requires.
  def test_a_load_path_directory_names_a_target_outside_lib
    Dir.mktmpdir do |dir|
      repo = File.join(dir, "repo")
      FileUtils.mkdir_p(File.join(repo, "lib"))
      FileUtils.mkdir_p(File.join(repo, "app/models"))
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
      assert_includes File.read(test), "\nrequire \"shop\"\nrequire \"cart\"\n"
      _out, err, status = Open3.capture3(RbConfig.ruby, "-I", File.join(repo, "lib"), "-I", File.join(repo, "app/models"), test)
      assert status.success?, err

      _out, err, status = run_cli(*args)
      refute status.success?
      assert_includes err, "cannot load such file -- sizing"
      File.write(File.join(repo, "app/models/plain.rb"), "module Plain\n  def self.size(n) = n > Shop::LIMIT ? :big : :small\nend\n")
      args[1, 2] = [File.join(repo, "app/models/plain.rb"), "Plain.size"]
      _out, err, status = run_cli(*args)
      assert status.success?, err
      assert_match %r{\Abranchout: \S*app/models/plain\.rb is under no -I or --require directory, so the emitted test requires it by path\.}, err
      assert_includes File.read(test), "# Required by path: no -I or --require directory holds "
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
      assert_includes stdout, "arms_covered: 1"
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
      assert_includes stdout, "arms_covered: 2\narms_total: 2\n"
      assert_empty stderr
    end
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

  # A check that moves from the entry into a parent class in another file
  # takes its arms out of arms_total. The report names that callee and how
  # many arms it has, so a smaller total does not read as less logic. An
  # attribute reader holds no logic, so it is not named.
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
      args = ["explore", child, "Child#label", "--require", parent, "--strategy", "inputs", "--random", "0", "--inputs", path]
      stdout, stderr, status = run_cli(*args)
      assert status.success?, stderr
      assert_includes stdout, "arms_total: 4\nexceptions: 0\ncallees_not_counted: 2\n"
      assert stdout.end_with?(<<~TEXT), stdout
        NOT COUNTED
        callee: Parent#checked
        loc: #{parent}:4
        arms: 2

        callee: Parent#plain
        loc: #{parent}:10
        arms: 0
      TEXT

      stdout, stderr, status = run_cli(*args, "--json")
      assert status.success?, stderr
      assert_equal [
        { "callee" => "Parent#checked", "loc" => "#{parent}:4", "arms" => 2 },
        { "callee" => "Parent#plain", "loc" => "#{parent}:10", "arms" => 0 }
      ], JSON.parse(stdout)["not_counted"]
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
        "explore", "test/fixtures/magic.rb", "FixtureMagic.classify",
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
      assert_includes stdout, "arms_covered: 2"
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
    %w[explore t.rb A.b --verbose] => "unknown option --verbose",
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
      stdout, stderr, status = run_cli("explore", target, "Noisy.f", "--strategy", "inputs", "--random", "0", "--inputs", path)
      assert status.success?, stderr
      assert_empty stderr
      assert stdout.start_with?("branchout explore\n")
      refute_includes stdout, "to stdout"
      # The load-time call took the :big arm; only the inputs' arms count.
      assert_includes stdout, "FRONTIER\nid: if@8:4/then@8:12\n"
      assert_includes stdout, "message: #{"z" * 180}\n"

      path = write_inputs(dir, { "inputs" => [[2]] })
      stdout, stderr, status = run_cli("explore", target, "Noisy#g", "--strategy", "inputs", "--random", "0", "--inputs", path)
      assert status.success?, stderr
      assert_includes stdout, "arms_covered: 1"
    end
  end
end
