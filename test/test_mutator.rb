# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "tmpdir"
require "branchout"

class MutatorTest < Minitest::Test
  def setup
    @root = File.expand_path("..", __dir__)
  end

  def test_magic_pool_contains_the_literal_not_only_neighbors
    target = Branchout::Target.parse(File.join(@root, "test/fixtures/magic.rb"), "FixtureMagic.classify")
    inputs = Branchout::Mutator.new(target, cap: 64).inputs.map { |input| input.args }
    assert_includes inputs, [114514]
    assert_includes inputs, [0]
    assert_includes inputs, [114513]
  end

  def test_arithmetic_pool_does_not_solve_the_congruence
    target = Branchout::Target.parse(File.join(@root, "test/fixtures/arith.rb"), "FixtureArith.classify")
    inputs = Branchout::Mutator.new(target, cap: 256).inputs
    solved = inputs.any? do |input|
      x = input.args[0]
      x.is_a?(Integer) && ((x * 3) + 7) % 1000 == 421
    end
    refute solved
  end

  def test_cap_is_deterministic
    target = Branchout::Target.parse(File.join(@root, "test/fixtures/arith.rb"), "FixtureArith.classify")
    first = Branchout::Mutator.new(target, cap: 10).inputs.map(&:canonical)
    second = Branchout::Mutator.new(target, cap: 10).inputs.map(&:canonical)
    assert_equal first, second
    assert_equal 10, first.length
    assert_equal first, first.sort
  end

  def test_input_file_ignores_meta_and_accepts_shorthand
    path = File.join(@root, "test/fixtures/sample_inputs.json")
    File.write(path, JSON.generate({
      "meta" => { "note" => "kept by the agent" },
      "types" => ["int", "int"],
      "inputs" => [[0, 1], { "args" => [2, 3], "kwargs" => {} }]
    }))
    inputs, types = Branchout::InputFile.load(path)
    assert_equal ["int", "int"], types
    assert_equal [[0, 1], [2, 3]], inputs.map(&:args)
  ensure
    File.delete(path) if path && File.file?(path)
  end

  def test_input_file_reads_new_and_refuses_a_nested_one
    Dir.mktmpdir do |dir|
      path = File.join(dir, "inputs.json")
      File.write(path, JSON.generate({ "inputs" => [{ "args" => [1], "new" => [2] }, [3]] }))
      inputs, _types = Branchout::InputFile.load(path)
      assert_equal [[2], nil], inputs.map { |input| input.receiver&.args }
      assert_equal '{"args":[1],"kwargs":{},"new":{"args":[2],"kwargs":{}}}', inputs.first.canonical

      File.write(path, JSON.generate({ "inputs" => [{ "args" => [], "new" => { "args" => [], "new" => [] } }] }))
      error = assert_raises(Branchout::Error) { Branchout::InputFile.load(path) }
      assert_match(/new cannot have its own new/, error.message)
    end
  end
end
