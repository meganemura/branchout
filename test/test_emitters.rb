# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "open3"
require "branchout"

class EmitterTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  BIN = File.join(ROOT, "bin/branchout")

  def test_format_resolution
    assert_equal "minitest", Branchout::Emitters.resolve(nil, "out/magic_test.rb")
    assert_equal "rspec", Branchout::Emitters.resolve(nil, "spec/generated/magic_value_spec.rb")
    assert_equal "minitest", Branchout::Emitters.resolve("minitest", "spec/generated/magic_value_spec.rb")
    assert_equal "rspec", Branchout::Emitters.resolve("rspec", "test/generated/magic_value_test.rb")
    error = assert_raises(Branchout::Error) { Branchout::Emitters.resolve("pytest", "x.rb") }
    assert_match(/format must be/, error.message)
  end

  def test_rspec_emitter_matches_minitest_cases
    Dir.mktmpdir do |dir|
      inputs = File.join(dir, "inputs.json")
      File.write(inputs, JSON.generate({
        "inputs" => [{ "args" => [0, 0] }, { "args" => [11, 11] }, { "args" => [24, 12] }]
      }))
      spec = File.join(dir, "scale_spec.rb")
      test = File.join(dir, "scale_test.rb")
      _out, err, status = run_cli(
        "explore", "test/fixtures/scale.rb", "FixtureScale.scale",
        "--inputs", inputs, "--strategy", "inputs", "--random", "0",
        "--emit-tests", spec
      )
      assert status.success?, err
      _out, err, status = run_cli(
        "explore", "test/fixtures/scale.rb", "FixtureScale.scale",
        "--inputs", inputs, "--strategy", "inputs", "--random", "0",
        "--emit-tests", test, "--format", "minitest"
      )
      assert status.success?, err

      spec_source = File.read(spec)
      test_source = File.read(test)
      assert_includes spec_source, "RSpec.describe FixtureScale do\n  describe \".scale\" do\n"
      assert_includes spec_source, "expect(FixtureScale.scale(0, 0)).to eq(:out_of_range)"
      assert_includes spec_source, "expect(FixtureScale.scale(11, 11)).to eq(-91)"
      assert_includes spec_source, 'expect { FixtureScale.scale(24, 12) }.to raise_error(ZeroDivisionError, "divided by 0")'
      refute_includes spec_source, "minitest"
      assert_includes test_source, "assert_equal :out_of_range, FixtureScale.scale(0, 0)"
      assert_includes test_source, "assert_raises(ZeroDivisionError)"
      assert_equal spec_source, File.read(spec)
    end
  end

  # A name says what the test pins. An input that no other input shares its
  # words with keeps its name when inputs are added.
  def test_emitted_names_say_what_they_pin
    Dir.mktmpdir do |dir|
      sources = [[[0, 0], [24, 12]], [[0, 0], [24, 12], [11, 11], [-3, 5]]].map do |list|
        inputs = File.join(dir, "inputs.json")
        File.write(inputs, JSON.generate({ "inputs" => list }))
        %w[scale_test.rb scale_spec.rb].map do |name|
          out = File.join(dir, name)
          _out, err, status = run_cli(
            "explore", "test/fixtures/scale.rb", "FixtureScale.scale",
            "--inputs", inputs, "--strategy", "inputs", "--random", "0", "--emit-tests", out
          )
          assert status.success?, err
          File.read(out)
        end
      end
      test_names = sources.map { |test, _spec| test.scan(/^  def (test_\w+)$/).flatten }
      assert_match(/\Atest_0_0_returns_out_of_range\z/, test_names[0][0])
      assert_match(/\Atest_24_12_raises_zero_division_error\z/, test_names[0][1])
      assert_includes test_names[1], "test_neg3_5_returns_out_of_range"
      assert_empty test_names[0] - test_names[1]
      assert_equal test_names[1].uniq, test_names[1]

      spec_names = sources.map { |_test, spec| spec.scan(/^    it (".*") do$/).flatten }
      assert_equal ['"returns :out_of_range when a is 0 and b is 0"', '"raises ZeroDivisionError when a is 24 and b is 12"'], spec_names[0]
      assert_empty spec_names[0] - spec_names[1]
    end
  end

  def test_a_target_that_mutates_its_arguments_sees_the_values_the_test_passes
    Dir.mktmpdir do |dir|
      inputs = File.join(dir, "inputs.json")
      File.write(inputs, JSON.generate({ "inputs" => [[[], "a"]] }))
      test = File.join(dir, "grow_test.rb")
      stdout, err, status = run_cli(
        "explore", "test/fixtures/grow.rb", "FixtureGrow.add",
        "--inputs", inputs, "--strategy", "inputs", "--random", "0",
        "--emit-tests", test
      )
      assert status.success?, err
      assert_includes stdout, "input: [[],\"a\"]"
      assert_includes stdout, "EXCEPTIONS\n(none)"
      assert_includes File.read(test), "assert_equal :one, FixtureGrow.add([], +\"a\")"

      _out, err, status = Open3.capture3(RbConfig.ruby, test)
      assert status.success?, err
    end
  end

  def test_a_value_with_no_literal_is_pinned_by_its_class
    Dir.mktmpdir do |dir|
      inputs = File.join(dir, "inputs.json")
      File.write(inputs, JSON.generate({ "inputs" => [[1]] }))
      test = File.join(dir, "shape_test.rb")
      spec = File.join(dir, "shape_spec.rb")
      [test, spec].each do |destination|
        _out, err, status = run_cli(
          "explore", "test/fixtures/shape.rb", "FixtureShape.build",
          "--inputs", inputs, "--strategy", "inputs", "--random", "0", "--emit-tests", destination
        )
        assert status.success?, err
      end
      assert_includes File.read(test), "assert_kind_of FixtureShape::Point, FixtureShape.build(1)"
      assert_includes File.read(spec), "expect(FixtureShape.build(1)).to be_a(FixtureShape::Point)"
      _out, err, status = Open3.capture3(RbConfig.ruby, test)
      assert status.success?, err
    end
  end

  def test_a_hash_return_value_emits_valid_minitest
    Dir.mktmpdir do |dir|
      inputs = File.join(dir, "inputs.json")
      File.write(inputs, JSON.generate({ "inputs" => [[0]] }))
      test = File.join(dir, "shape_test.rb")
      _out, err, status = run_cli(
        "explore", "test/fixtures/shape.rb", "FixtureShape.build",
        "--inputs", inputs, "--strategy", "inputs", "--random", "0", "--emit-tests", test
      )
      assert status.success?, err
      # The expected Hash keeps the value's own key order, so a failure diff
      # lines up key by key with the actual value.
      assert_includes File.read(test), 'assert_equal({"n" => 0, "as" => :zero}, FixtureShape.build(0))'
      _out, err, status = Open3.capture3(RbConfig.ruby, test)
      assert status.success?, err
    end
  end

  # NameError and NoMethodError reword their messages between Ruby 3.3 and
  # 3.4, so their pin is the missing name.
  def test_a_name_error_is_pinned_by_its_name_not_its_message
    Dir.mktmpdir do |dir|
      target = File.join(dir, "names.rb")
      File.write(target, "module T\n  def self.f(x) = x.zero? ? x.upcase : Missing\nend\n")
      inputs = File.join(dir, "inputs.json")
      File.write(inputs, JSON.generate({ "inputs" => [[0], [1]] }))
      test = File.join(dir, "names_test.rb")
      spec = File.join(dir, "names_spec.rb")
      [test, spec].each do |path|
        _out, err, status = run_cli(
          "explore", target, "T.f", "--inputs", inputs, "--strategy", "inputs", "--random", "0", "--emit-tests", path
        )
        assert status.success?, err
      end
      test_source = File.read(test)
      assert_includes test_source, "    error = assert_raises(NoMethodError) do\n      T.f(0)\n    end\n" \
                                   "    assert_equal :upcase, error.name\n"
      assert_includes test_source, "    assert_equal :Missing, error.name\n"
      refute_includes test_source, "undefined"
      spec_source = File.read(spec)
      assert_includes spec_source, "expect { T.f(0) }.to raise_error(NoMethodError) { |error| expect(error.name).to eq(:upcase) }"
      assert_includes spec_source, "expect { T.f(1) }.to raise_error(NameError) { |error| expect(error.name).to eq(:Missing) }"
      _out, err, status = Open3.capture3(RbConfig.ruby, test)
      assert status.success?, err
    end
  end

  # explore calls a private or protected method, and so does the emitted
  # test, through send. A private new is reached the same way.
  def test_private_and_protected_targets_and_a_private_new_are_called_through_send
    Dir.mktmpdir do |dir|
      cases = {
        "FixtureVault#check" => [{ "new" => [3], "args" => [3] }, { "new" => [3], "args" => [4] }],
        "FixtureVault#peek" => [{ "new" => [3], "args" => [3] }],
        "FixtureVault#unlock" => [{ "new" => [3], "args" => [4] }],
        "FixtureVault.seal" => [[""], ["a"]]
      }
      paths = cases.flat_map do |entry, list|
        inputs = File.join(dir, "inputs.json")
        File.write(inputs, JSON.generate({ "inputs" => list }))
        %w[test.rb spec.rb].map do |suffix|
          path = File.join(dir, "#{entry.tr("#.", "__").downcase}_#{suffix}")
          stdout, err, status = run_cli(
            "explore", "test/fixtures/vault.rb", entry,
            "--inputs", inputs, "--strategy", "inputs", "--random", "0", "--emit-tests", path
          )
          assert status.success?, err
          assert_includes stdout, "EXCEPTIONS\n(none)"
          path
        end
      end
      tests, specs = paths.partition { |path| path.end_with?("_test.rb") }
      # One process per format: each emitted file loads on its own.
      out, err, status = Open3.capture3(RbConfig.ruby, "-e", "ARGV.each { |path| require path }", *tests)
      assert status.success?, err + out
      assert_includes out, "6 runs, 6 assertions, 0 failures, 0 errors"
      out, err, status = Open3.capture3(RbConfig.ruby, "-rrspec/autorun", "-e", "", *specs)
      assert status.success?, err + out
      assert_includes out, "6 examples, 0 failures"
      sources = paths.map { |path| File.read(path) }.join
      assert_includes sources, "assert_equal :open, FixtureVault.send(:new, 3).send(:check, 3)"
      assert_includes sources, "let(:fixture_vault) { FixtureVault.send(:new, 3) }"
      assert_includes sources, "expect(fixture_vault.send(:peek, 3)).to eq(:match)"
      assert_includes sources, "assert_equal :shut, FixtureVault.send(:new, 3).unlock(4)"
      assert_includes sources, 'expect(FixtureVault.send(:seal, +"")).to eq(:blank)'
    end
  end

  # A private new is not a dead end: its arguments still go in "new".
  def test_a_private_new_without_arguments_says_they_go_in_new
    Dir.mktmpdir do |dir|
      inputs = File.join(dir, "inputs.json")
      File.write(inputs, JSON.generate({ "inputs" => [[3]] }))
      _out, err, status = run_cli(
        "explore", "test/fixtures/vault.rb", "FixtureVault#check", "--inputs", inputs, "--strategy", "inputs", "--random", "0"
      )
      refute status.success?
      assert_includes err, "FixtureVault#initialize requires 1 arguments; give them in \"new\" on each input. " \
                           "FixtureVault.new is private, so explore and the emitted tests call it through send."
    end
  end

  def test_a_nil_return_value_emits_assert_nil
    Dir.mktmpdir do |dir|
      inputs = File.join(dir, "inputs.json")
      File.write(inputs, JSON.generate({ "inputs" => [[-1]] }))
      test = File.join(dir, "shape_test.rb")
      _out, err, status = run_cli(
        "explore", "test/fixtures/shape.rb", "FixtureShape.build",
        "--inputs", inputs, "--strategy", "inputs", "--random", "0", "--emit-tests", test
      )
      assert status.success?, err
      assert_includes File.read(test), "assert_nil FixtureShape.build(-1)"
      _out, err, status = Open3.capture3(RbConfig.ruby, test)
      assert status.success?, err
    end
  end

  def test_literals_calls_and_class_names
    support = Branchout::Emitters::Support
    assert_equal '{"b" => true, c: +"x", "a" => [nil, false], d?: 1, "e f": 2, "+": 3}',
                 support.ruby_literal({ "b" => true, c: "x", "a" => [nil, false], d?: 1, "e f": 2, "+": 3 }, mutable: true)
    target = Struct.new(:singleton, :const_name, :method_name, :entry).new(true, "Foo::Bar", :baz?, "Foo::Bar.baz?")
    input = Branchout::Input.new(args: [1], kwargs: { "z" => 1, "a b" => "s" })
    assert_equal [[], 'Foo::Bar.baz?(1, "a b": +"s", z: 1)'], support.arrange(target, input)
    target.singleton = false
    setup = [Branchout::Input::SetupCall.new("<<", Branchout::Input.new(args: ["x"])), Branchout::Input::SetupCall.new("clear", Branchout::Input.new(args: []))]
    assert_equal [["bar = Foo::Bar.new(2)", 'bar.send(:<<, +"x")', "bar.clear"], "bar.baz?"],
                 support.arrange(target, Branchout::Input.new(args: [], receiver: Branchout::Input.new(args: [2]), setup: setup))
    { "HTTPClient" => "http_client", "Class" => "subject", "Error" => "subject", "X" => "x" }.each do |const, name|
      target.const_name = const
      assert_equal name, support.receiver_name(target), const
    end
    target.const_name = "Foo::Bar"
    target.singleton = true
    assert_equal "FooBarBazPCharacterizationTest", support.class_name_for(target)
    target.method_name = :reset!
    assert_equal "FooBarResetBCharacterizationTest", support.class_name_for(target)
    target.const_name = "JitCatch::Render"
    target.method_name = :run_text
    assert_equal "JitCatchRenderRunTextCharacterizationTest", support.class_name_for(target)
  end

  # A blank argument still shows in the name, and the outcome is cut at a
  # word boundary, with a Hash outcome named by its keys.
  def test_names_keep_blank_arguments_and_cut_at_word_boundaries
    pin = ->(args, value, error = nil) {
      Branchout::Engine::Pin.new(input: Branchout::Input.new(args: args), value: value, error: error, arm_ids: [])
    }
    receipt = { discount: 50, discount_cents: 0, due_cents: 999, lines: [{ qty: 1 }] }
    error = Branchout::Runner::ExceptionInfo.new(class_name: "ArgumentError")
    names = Branchout::Emitters::Support.test_names([
      pin.(["   ", 1], nil, error),
      pin.([""], :ok),
      pin.([50], receipt),
      pin.([51], { "line_items" => [], sum: 0, "discount" => 1 }),
      pin.([1], "raised ArgumentError: bad quantity"),
      pin.([2], [[1, 2], [3]]),
      pin.([3], {})
    ])
    expected = [
      /\Atest_blank_1_raises_argument_error\z/,
      /\Atest_empty_returns_ok\z/,
      /\Atest_50_returns__discount_50\z/,
      /\Atest_51_returns__sum_0__discount_1\z/,
      /\Atest_1_returns_raised_argumenterror\z/,
      /\Atest_2_returns_array_of_2\z/,
      /\Atest_3_returns_empty_hash\z/
    ]
    expected.zip(names).each { |pattern, name| assert_match pattern, name }

    # A Hash argument is named by its values, and a collection nested in an
    # argument by its kind, so a tree of arguments still reads.
    error = Branchout::Runner::ExceptionInfo.new(class_name: "QuintDriver::Unsupported")
    tree = [{ "kind" => "name", "name" => "l" }, { "kind" => "app", "args" => [{ "kind" => "int", "value" => -1 }] }]
    nested = Branchout::Engine::Pin.new(input: Branchout::Input.new(args: tree, kwargs: { "env" => 1 }), value: nil, error: error, arm_ids: [])
    assert_match(/\Atest_name_l_app_array_env_1_raises_quint_driver\z/, Branchout::Emitters::Support.test_names([nested]).first)

    point = Struct.new(:x)
    long_word = "a" * 50
    names = Branchout::Emitters::Support.test_names([pin.([long_word], Set[1]), pin.([4], point.new(4))])
    assert_match(/\Atest_#{"a" * 40}_returns_set\z/, names[0])
    assert_match(/\Atest_4_returns_struct\z/, names[1])
  end

  # Inputs whose names would differ only in a digest are named by the leaves
  # that differ between them. A key one input lacks reads "none".
  def test_sibling_inputs_are_named_by_the_leaves_that_differ
    pin = ->(args) { Branchout::Engine::Pin.new(input: Branchout::Input.new(args: args), value: :ok, error: nil, arm_ids: []) }
    head = ->(fields) { { "methods" => [{ "id" => "m1" }], "tests" => [{ "id" => "t1", "head" => fields }] } }
    pins = [
      pin.([head.({ "status" => "fail", "error_class" => "Minitest::Assertion" })]),
      pin.([head.({ "status" => "timeout", "error_class" => "Timeout" })]),
      pin.([head.({ "status" => "pass" })]),
      pin.([1]),
      pin.(["!"]),
      pin.(["?"])
    ]
    names = Branchout::Emitters::Support.test_names(pins)
    assert_equal "test_status_fail__error_class_minitest_returns_ok", names[0]
    assert_equal "test_status_timeout__error_class_timeout_returns_ok", names[1]
    assert_equal "test_status_pass__error_class_none_returns_ok", names[2]
    assert_equal "test_1_returns_ok", names[3]
    assert_match(/\Atest_text_returns_ok_\h{6}\z/, names[4])
    assert_match(/\Atest_text_returns_ok_\h{6}\z/, names[5])
    refute_equal names[4], names[5]
  end

  # Keywords, new, and setup calls are leaves too, and an empty collection
  # reads "empty".
  def test_siblings_differ_in_keywords_new_setup_and_empty_values
    support = Branchout::Emitters::Support
    pin = ->(input) { Branchout::Engine::Pin.new(input: input, value: :ok, error: nil, arm_ids: []) }
    input = ->(**parts) { Branchout::Input.new(args: [], **parts) }
    call = ->(name, arg) { Branchout::Input::SetupCall.new(name, Branchout::Input.new(args: [arg])) }
    names = support.test_names([[{ "a" => [] }], [{ "a" => {} }], [{ "a" => 1 }]].map { |arg| pin.(Branchout::Input.new(args: [{ "x" => arg.first }])) })
    assert_match(/\Atest_a_empty_returns_ok_\h{6}\z/, names[0])
    assert_match(/\Atest_a_empty_returns_ok_\h{6}\z/, names[1])
    assert_equal "test_a_1_returns_ok", names[2]
    assert_equal %w[test_b_1_returns_ok test_b_2_returns_ok],
                 support.test_names([1, 2].map { |n| pin.(input.(kwargs: { "k" => { "a" => { "b" => n } } })) })
    assert_equal %w[test_b_1_returns_ok test_b_2_returns_ok],
                 support.test_names([1, 2].map { |n| pin.(input.(receiver: Branchout::Input.new(args: [{ "a" => { "b" => n } }]))) })
    assert_equal %w[test_b_1_returns_ok test_b_2_returns_ok],
                 support.test_names([1, 2].map { |n| pin.(input.(setup: [call.("add", { "a" => { "b" => n } })])) })
    names = support.test_names(%w[add! add?].map { |name| pin.(input.(setup: [call.(name, {})])) })
    names.each { |name| assert_match(/\Atest_add_returns_ok_\h{6}\z/, name) }
  end

  # Hash outcomes with the same keys are named by the scalar entries that
  # differ between them, so the name says how the results differ.
  def test_hash_outcomes_are_named_by_the_entries_that_differ
    snapshot = ->(due, discount) { { lines: [{ sku: "A" }], discount: 10, due_cents: due, discount_cents: discount } }
    pins = [[1, snapshot.(0, 1000)], [2, snapshot.(900, 100)], [3, :none]].map do |arg, value|
      Branchout::Engine::Pin.new(input: Branchout::Input.new(args: [arg]), value: value, error: nil, arm_ids: [])
    end
    assert_equal %w[test_1_returns__due_cents_0 test_2_returns__due_cents_900 test_3_returns_none],
                 Branchout::Emitters::Support.test_names(pins)
  end

  # A scalar deep in a Hash argument reaches the name: 7 % 0, -7 % 3, and
  # 7 % 3 as quint IR differ only in two nested ints.
  def test_a_scalar_inside_a_nested_hash_names_its_sibling
    modulo = ->(a, b) { { "kind" => "app", "opcode" => "imod", "args" => [{ "kind" => "int", "value" => a }, { "kind" => "int", "value" => b }] } }
    pins = [[7, 0], [-7, 3], [7, 3]].map do |a, b|
      Branchout::Engine::Pin.new(input: Branchout::Input.new(args: [modulo.(a, b)], receiver: Branchout::Input.new(args: [[], []])),
                                 value: :ok, error: nil, arm_ids: [])
    end
    assert_equal %w[test_value_7__value_0_returns_ok test_value_neg7__value_3_returns_ok test_value_7__value_3_returns_ok],
                 Branchout::Emitters::Support.test_names(pins)
  end

  # Strings that share their start are named by the words from where they
  # part.
  def test_sibling_strings_are_named_from_where_they_differ
    support = Branchout::Emitters::Support
    diff = ->(old, new) { "--- expected\n+++ actual\n@@ -1 +1 @@\n \"classification\" => \"candidate\",\n-\"status\" => \"#{old}\"\n+\"status\" => \"#{new}\"\n" }
    pins = [%w[fail pass], %w[pass fail], %w[error timeout]].map do |old, new|
      Branchout::Engine::Pin.new(input: Branchout::Input.new(args: [diff.(old, new), 1]), value: :ok, error: nil, arm_ids: [])
    end
    assert_equal %w[test_fail_status_pass_returns_ok test_pass_status_fail_returns_ok test_error_status_timeout_returns_ok],
                 support.test_names(pins)
  end

  # A leaf that is a String in one sibling and not in another keeps all of
  # its words.
  def test_a_string_beside_a_number_keeps_its_start
    pins = [1, "1 a"].map do |value|
      Branchout::Engine::Pin.new(input: Branchout::Input.new(args: [{ "x" => { "v" => value } }]), value: :ok, error: nil, arm_ids: [])
    end
    assert_equal %w[test_v_1_returns_ok test_v_1_a_returns_ok], Branchout::Emitters::Support.test_names(pins)
  end

  def test_requires_by_name_come_from_each_require_directory
    support = Branchout::Emitters::Support
    lines = support.require_lines(["/w/repo/lib/shop.rb"], "/w/repo/lib/shop/cart.rb", "/tmp/out/cart_test.rb", by_name: true)
    assert_equal ['require "shop"', 'require "shop/cart"'], lines
    lines = support.require_lines(["/w/repo/lib/shop.rb"], "/w/other/cart.rb", "/w/repo/test/cart_test.rb", by_name: true)
    assert_equal ['require "shop"', 'require_relative "../../other/cart.rb"'], lines
    lines = support.require_lines(["/w/repo/lib/shop.rb"], "/w/repo/lib/shop/cart.rb", "/w/repo/test/cart_test.rb")
    assert_equal ['require_relative "../lib/shop.rb"', 'require_relative "../lib/shop/cart.rb"'], lines
  end

  # A setter or an operator in a setup call has no plain form that keeps
  # its arguments, so it goes through send.
  def test_a_setter_or_an_operator_is_called_through_send
    support = Branchout::Emitters::Support
    assert_equal "cart.send(:limit=)", support.call_text("cart", "limit=", "", [])
    assert_equal "cart.send(:limit=, a: 1)", support.call_text("cart", "limit=", "a: 1", [])
    assert_equal "cart.send(:<<, 1)", support.call_text("cart", "<<", "1", [])
    assert_equal "cart.empty?", support.call_text("cart", "empty?", "", [])
    assert_equal "cart.add(1)", support.call_text("cart", "add", "1", [])
  end

  def test_clip_keeps_a_word_that_fills_the_limit
    support = Branchout::Emitters::Support
    assert_equal "abcd", support.clip(["abcd"], 4)
    assert_equal "abc", support.clip(["abcd"], 3)
    assert_equal "ab_c", support.clip(%w[ab c], 4)
    assert_equal "ab", support.clip(%w[ab cd], 4)
    key = Branchout::Emitters::Support::Key
    assert_equal "returns__due_cents_0", support.clip(["returns", key.new("due_cents"), "0", key.new("discount_cents"), "1000"], 30)
    assert_equal "hash__lines__discount", support.clip(["hash", key.new("lines"), key.new("discount"), key.new("due_cents")], 25)
  end

  def test_an_emitted_file_creates_its_directory
    Dir.mktmpdir do |dir|
      target = Struct.new(:singleton, :const_name, :method_name, :entry, :display_path, :path)
                     .new(true, "Foo", :bar, "Foo.bar", "lib/foo.rb", File.join(dir, "lib/foo.rb"))
      destination = File.join(dir, "new/dir/foo_test.rb")
      Branchout::Emitters.write("minitest", Branchout::Engine::Result.new(pins: [], requires: []), target, destination)
      assert_includes File.read(destination), "def test_no_inputs_discovered"
    end
  end

  def test_explicit_format_overrides_extension
    Dir.mktmpdir do |dir|
      inputs = File.join(dir, "inputs.json")
      File.write(inputs, JSON.generate({ "inputs" => [{ "args" => [0] }] }))
      destination = File.join(dir, "magic_spec.rb")
      _out, err, status = run_cli(
        "explore", "test/fixtures/magic.rb", "FixtureMagic.classify",
        "--inputs", inputs, "--strategy", "inputs", "--random", "0",
        "--emit-tests", destination, "--format", "minitest"
      )
      assert status.success?, err
      source = File.read(destination)
      assert_includes source, "Minitest::Test"
      refute_includes source, "RSpec.describe"
    end
  end

  def test_rspec_render_is_stable
    target = Branchout::Target.parse(File.join(ROOT, "test/fixtures/magic.rb"), "FixtureMagic.classify")
    result = Branchout::Engine.explore(
      target: target.path,
      entry: "FixtureMagic.classify",
      user_inputs: [Branchout::Input.new(args: [0]), Branchout::Input.new(args: [114514])],
      strategies: ["inputs"],
      random: 0
    )
    destination = File.join(ROOT, "spec/generated/magic_value_spec.rb")
    first = Branchout::Emitters.render("rspec", result, target, destination)
    second = Branchout::Emitters.render("rspec", result, target, destination)
    assert_equal first, second
    assert_includes first, "expect(FixtureMagic.classify(114514)).to eq(:magic)"
  end

  def run_cli(*args)
    Open3.capture3(RbConfig.ruby, BIN, *args.map(&:to_s), chdir: ROOT)
  end

  def test_literal_values_class_pins_and_cover_comments
    support = Branchout::Emitters::Support
    [nil, true, false, 1, "s", :s, [nil], { "a" => false }].each { |value| assert support.literal?(value), value.inspect }
    refute support.literal?({ Object.new => 1 })
    refute support.literal?({ "a" => Object.new })
    assert_equal "Struct", support.class_literal(Struct.new(:a).new(1))
    pin = Branchout::Engine::Pin.new(input: Branchout::Input.new(args: []), value: 1, error: nil, arm_ids: [])
    assert_empty support.cover_comment(pin, "  ")
  end

  # A receiver built in statements appears in both formats, before the
  # entry call, for a returned value and for a raised error.
  def test_setup_statements_come_before_the_entry_in_both_formats
    target = Struct.new(:singleton, :const_name, :method_name, :entry, :display_path, :path)
                   .new(false, "Shop::Cart", :total, "Shop::Cart#total", "lib/cart.rb", File.join(ROOT, "lib/cart.rb"))
    setup = [Branchout::Input::SetupCall.new("add", Branchout::Input.new(args: ["apple"], kwargs: { "qty" => 2 }))]
    input = Branchout::Input.new(args: [], receiver: Branchout::Input.new(args: ["EUR"]), setup: setup)
    error = Branchout::Runner::ExceptionInfo.new(class_name: "KeyError", message: "m", stable_message: false)
    pins = [nil, error].map { |raised| Branchout::Engine::Pin.new(input: input, value: 7, error: raised, arm_ids: []) }
    arrange = "cart = Shop::Cart.new(+\"EUR\")\n"
    pins.each do |pin|
      result = Branchout::Engine::Result.new(pins: [pin], requires: [], private_calls: [])
      minitest = Branchout::Emitters.render("minitest", result, target, File.join(ROOT, "test/cart_test.rb"))
      rspec = Branchout::Emitters.render("rspec", result, target, File.join(ROOT, "spec/cart_spec.rb"))
      if pin.error
        assert_includes minitest, "    error = assert_raises(KeyError) do\n      #{arrange}      cart.add(+\"apple\", qty: 2)\n      cart.total\n    end\n"
        assert_includes rspec, "    let(:cart) { Shop::Cart.new(+\"EUR\") }\n\n    it \"raises KeyError after add(\\\"apple\\\", qty: 2)\" do\n" \
                               "      expect {\n        cart.add(+\"apple\", qty: 2)\n        total\n      }.to raise_error(KeyError)\n"
      else
        assert_includes minitest, "    #{arrange}    cart.add(+\"apple\", qty: 2)\n    assert_equal 7, cart.total\n"
        assert_includes rspec, "    subject(:total) { cart.total }\n\n    let(:cart) { Shop::Cart.new(+\"EUR\") }\n\n" \
                               "    before do\n      cart.add(+\"apple\", qty: 2)\n    end\n\n    it \"returns 7\" do\n      expect(total).to eq(7)\n"
      end
    end
    name = Branchout::Emitters::Support.test_names(pins.take(1)).first
    assert_match(/\Atest_new_eur_add_apple_qty_2_returns_7\z/, name)
  end

  def test_names_and_outcomes_of_keywords_nil_and_long_values
    pin = ->(value) { Branchout::Engine::Pin.new(input: Branchout::Input.new(args: [1]), value: value, error: nil, arm_ids: []) }
    keywords = Branchout::Engine::Pin.new(input: Branchout::Input.new(args: [1], kwargs: { "k" => 2 }), value: nil, error: nil, arm_ids: [])
    assert_match(/\Atest_1_k_2_returns_nil\z/, Branchout::Emitters::Support.test_names([keywords]).first)
    outcome = ->(value) { Branchout::Emitters::Support.outcomes([pin.(value)]).values.first }
    assert_equal "returns #{("a" * 38).inspect}", outcome.("a" * 38)
    assert_equal "returns a String of 39 characters", outcome.("a" * 39)
    assert_equal "returns an Array of 20", outcome.([1] * 20)
    assert_equal "returns a Hash of #{(1..9).map { |n| "key#{n}" }.join(", ")}", outcome.((1..9).to_h { |n| [:"key#{n}", n] })
    assert_equal "returns a Set", outcome.(Set[1])
    assert_equal "returns an Object", outcome.(Object.new)
  end

  # Inputs that share their first steps share a context with the let or
  # the before that holds them; a raising input keeps its calls inline; the
  # facts every input shares are left out.
  def test_rspec_groups_inputs_by_the_steps_they_share
    target = Struct.new(:singleton, :const_name, :method_name, :entry, :display_path, :path, :parameters, :positional)
                   .new(false, "Shop::Cart", :total, "Shop::Cart#total", "lib/cart.rb", File.join(ROOT, "lib/cart.rb"),
                        [], [Struct.new(:name).new(:tax), Struct.new(:name).new(:round)])
    call = ->(name, *args) { Branchout::Input::SetupCall.new(name, Branchout::Input.new(args: args)) }
    pin = lambda do |args, value, new: nil, setup: [], error: nil|
      input = Branchout::Input.new(args: args, receiver: new && Branchout::Input.new(args: new), setup: setup)
      Branchout::Engine::Pin.new(input: input, value: value, error: error, arm_ids: [])
    end
    error = Branchout::Runner::ExceptionInfo.new(class_name: "ArgumentError", message: "m", stable_message: true)
    pins = [
      pin.([1, true], 0),
      pin.([1, true], 300, setup: [call.("add", "apple", 3)]),
      pin.([2, true], 600, setup: [call.("add", "apple", 3)]),
      pin.([1, true], 700, setup: [call.("add", "apple", 3), call.("add", "pear", 4)]),
      pin.([1, true], nil, setup: [call.("add", "apple", 0)], error: error),
      pin.([1, true], 5, new: ["EUR"])
    ]
    result = Branchout::Engine::Result.new(pins: pins, requires: [], private_calls: [])
    rspec = Branchout::Emitters.render("rspec", result, target, File.join(ROOT, "spec/cart_spec.rb"))
    assert_equal <<~'RUBY', rspec.split("\n\n", 4).last
      RSpec.describe Shop::Cart do
        describe "#total" do
          context "with new" do
            let(:cart) { Shop::Cart.new }

            it "returns 0 when tax is 1" do
              expect(cart.total(1, true)).to eq(0)
            end

            it "raises ArgumentError after add(\"apple\", 0) when tax is 1" do
              expect {
                cart.add(+"apple", 0)
                cart.total(1, true)
              }.to raise_error(ArgumentError, "m")
            end

            context "after add(\"apple\", 3)" do
              before do
                cart.add(+"apple", 3)
              end

              it "returns 300 when tax is 1" do
                expect(cart.total(1, true)).to eq(300)
              end

              it "returns 600 when tax is 2" do
                expect(cart.total(2, true)).to eq(600)
              end

              context "after add(\"pear\", 4)" do
                before do
                  cart.add(+"pear", 4)
                end

                it "returns 700 when tax is 1" do
                  expect(cart.total(1, true)).to eq(700)
                end
              end
            end
          end

          context "with new(\"EUR\")" do
            let(:cart) { Shop::Cart.new(+"EUR") }

            it "returns 5 when tax is 1" do
              expect(cart.total(1, true)).to eq(5)
            end
          end
        end
      end
    RUBY
  end

  # A test written outside the target's tree requires it by absolute path,
  # not by a climb to / that breaks once either file moves.
  def test_a_require_shares_a_directory_or_is_absolute
    support = Branchout::Emitters::Support
    assert_equal "../lib/a.rb", support.relative_require("/w/repo/test/a_test.rb", "/w/repo/lib/a.rb")
    assert_equal "./a.rb", support.relative_require("/w/repo/a_test.rb", "/w/repo/a.rb")
    assert_equal "/home/u/repo/lib/a.rb", support.relative_require("/tmp/out/a_test.rb", "/home/u/repo/lib/a.rb")
  end

  # A target outside the working directory is named from its project's
  # root, or from the emitted file when no project holds it, so a committed
  # header carries no machine path.
  def test_the_target_header_carries_no_machine_path
    Dir.mktmpdir do |dir|
      project = File.join(dir, "project")
      FileUtils.mkdir_p(File.join(project, "lib"))
      File.write(File.join(project, "Gemfile"), "")
      FileUtils.cp(File.join(ROOT, "test/fixtures/magic.rb"), File.join(project, "lib/magic.rb"))
      loose = File.join(dir, "loose")
      FileUtils.mkdir_p(loose)
      FileUtils.cp(File.join(ROOT, "test/fixtures/magic.rb"), File.join(loose, "magic.rb"))
      inputs = File.join(dir, "inputs.json")
      File.write(inputs, JSON.generate({ "inputs" => [[0]] }))
      [[File.join(project, "lib/magic.rb"), File.join(project, "test/magic_test.rb"), "lib/magic.rb"],
       [File.join(loose, "magic.rb"), File.join(loose, "test/magic_spec.rb"), "../magic.rb"]].each do |target, out, shown|
        _out, err, status = run_cli("explore", target, "FixtureMagic.classify", "--inputs", inputs,
                                    "--strategy", "inputs", "--random", "0", "--emit-tests", out)
        assert status.success?, err
        assert_includes File.read(out), "\n# target: #{shown}\n"
      end
    end
  end

  def test_an_empty_run_emits_a_skip_and_requires_load_first
    target = Struct.new(:singleton, :const_name, :method_name, :entry, :display_path, :path)
                   .new(true, "Foo", :bar, "Foo.bar", "lib/foo.rb", File.join(ROOT, "lib/foo.rb"))
    result = Branchout::Engine::Result.new(pins: [], requires: [File.join(ROOT, "lib/all.rb")])
    destination = File.join(ROOT, "test/foo_test.rb")
    minitest = Branchout::Emitters.render("minitest", result, target, destination)
    assert_includes minitest, "require_relative \"../lib/all.rb\"\nrequire_relative \"../lib/foo.rb\"\n"
    assert_includes minitest, "  def test_no_inputs_discovered\n    skip \"branchout did not discover an input\"\n  end\n"
    rspec = Branchout::Emitters.render("rspec", result, target, destination)
    assert_includes rspec, "require_relative \"../lib/all.rb\"\nrequire_relative \"../lib/foo.rb\"\n"
    assert_includes rspec, "    it \"discovers no inputs\" do\n      skip \"branchout did not discover an input\"\n    end\n"
  end
end
