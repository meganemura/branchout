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
      assert_includes spec_source, 'RSpec.describe "FixtureScale.scale" do'
      assert_includes spec_source, "expect(FixtureScale.scale(0, 0)).to eq(:out_of_range)"
      assert_includes spec_source, "expect(FixtureScale.scale(11, 11)).to eq(-91)"
      assert_includes spec_source, 'expect { FixtureScale.scale(24, 12) }.to raise_error(ZeroDivisionError, "divided by 0")'
      refute_includes spec_source, "minitest"
      assert_includes test_source, "assert_equal :out_of_range, FixtureScale.scale(0, 0)"
      assert_includes test_source, "assert_raises(ZeroDivisionError)"
      assert_equal spec_source, File.read(spec)
    end
  end

  # A name says what the test pins, and adding an input does not rename the
  # tests that were already there.
  def test_emitted_names_say_what_they_pin_and_survive_new_inputs
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
      assert_match(/\Atest_0_0_returns_out_of_range_\h{6}\z/, test_names[0][0])
      assert_match(/\Atest_24_12_raises_zero_division_error_\h{6}\z/, test_names[0][1])
      assert_includes test_names[1].join(" "), "test_neg3_5_returns_out_of_range_"
      assert_empty test_names[0] - test_names[1]
      assert_equal test_names[1].uniq, test_names[1]

      spec_names = sources.map { |_test, spec| spec.scan(/^  it (".*") do$/).flatten }
      assert_equal ['"[0,0] returns :out_of_range"', '"[24,12] raises ZeroDivisionError"'], spec_names[0]
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
      assert_includes File.read(test), 'assert_equal({"n" => 0}, FixtureShape.build(0))'
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
    assert_equal '{"a" => [nil, false], "b" => true, :c => +"x"}',
                 support.ruby_literal({ "b" => true, c: "x", "a" => [nil, false] }, mutable: true)
    target = Struct.new(:singleton, :const_name, :method_name, :entry).new(true, "Foo::Bar", :baz?, "Foo::Bar.baz?")
    input = Branchout::Input.new(args: [1], kwargs: { "z" => 1, "a b" => "s" })
    assert_equal [[], 'Foo::Bar.baz?(1, "a b": +"s", z: 1)'], support.arrange(target, input)
    target.singleton = false
    setup = [Branchout::Input::SetupCall.new("<<", Branchout::Input.new(args: ["x"]))]
    assert_equal [["bar = Foo::Bar.new(2)", 'bar.<<(+"x")'], "bar.baz?()"],
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
end
