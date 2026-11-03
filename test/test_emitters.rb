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
