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

  def test_every_mutated_input_passes_the_required_keywords
    target = Branchout::Target.parse(File.join(@root, "test/fixtures/pools.rb"), "FixturePools.mix")
    inputs = Branchout::Mutator.new(target, cap: 256).inputs
    assert(inputs.all? { |input| input.kwargs.keys == ["label"] })
    assert_includes inputs.map(&:kwargs), { "label" => "x" }
  end

  SAMPLED = "module T\n  def self.f(i, x, s, a, h, k:, opt: 1)\n    i + 1; x + 1.5; s.strip; a.first; h.keys\n  end\nend\n"

  def test_sampler_stream_and_domains
    Dir.mktmpdir do |dir|
      path = File.join(dir, "t.rb")
      File.write(path, SAMPLED)
      target = Branchout::Target.parse(path, "T.f")
      assert_equal [
        '{"args":[4,-1.5,"--",[],{"a":0,"b":10}],"kwargs":{"k":5}}',
        '{"args":[2,9.0,".c1",[1],{}],"kwargs":{"k":-2}}'
      ], Branchout::Sampler.new(target, seed: 1, count: 2).inputs.map(&:canonical)

      (0..20).flat_map { |seed| Branchout::Sampler.new(target, seed: seed, count: 8).inputs }.each do |input|
        int, float, string, array, hash = input.args
        assert_includes(-3..12, int)
        assert_includes(-3.0..12.5, float)
        assert_equal 0, (float * 2) % 1
        assert_match(/\A[abc01.-]{0,3}\z/, string)
        assert_operator array.length, :<=, 2
        assert_includes [[], %w[a], %w[a b]], hash.keys
        assert_equal ["k"], input.kwargs.keys
      end
    end
  end

  INPUT_FILE_ERRORS = {
    "[1" => "invalid JSON in",
    "{}" => "is missing \"inputs\"",
    "{\"inputs\": 1}" => "inputs must be an array",
    "{\"inputs\": [], \"types\": \"int\"}" => "types must be an array",
    "{\"inputs\": [], \"types\": [\"bool\"]}" => "has an unknown type (int, float, string, array, hash)",
    "{\"inputs\": [{\"args\": [], \"note\": 1}]}" => "inputs[0] has unknown keys: note",
    "{\"inputs\": [{\"kwargs\": {}}]}" => "inputs[0] is missing args",
    "{\"inputs\": [1]}" => "inputs[0] must be an array or an object",
    "{\"inputs\": [{\"args\": 1}]}" => "input args must be an array",
    "{\"inputs\": [{\"args\": [], \"kwargs\": 1}]}" => "input kwargs must be an object"
  }.freeze

  def test_each_bad_inputs_file_names_the_problem
    Dir.mktmpdir do |dir|
      path = File.join(dir, "inputs.json")
      error = assert_raises(Branchout::Error) { Branchout::InputFile.load(path) }
      assert_equal "inputs file not found: #{path}", error.message
      INPUT_FILE_ERRORS.each do |body, message|
        File.write(path, body)
        error = assert_raises(Branchout::Error, body) { Branchout::InputFile.load(path) }
        assert_includes error.message, message, body
      end
    end
  end

  def test_null_kwargs_is_no_keywords
    Dir.mktmpdir do |dir|
      path = File.join(dir, "inputs.json")
      File.write(path, JSON.generate({ "inputs" => [{ "args" => [nil], "kwargs" => nil }] }))
      inputs, types = Branchout::InputFile.load(path)
      assert_nil types
      assert_equal [[nil], {}], [inputs.first.args, inputs.first.kwargs]
    end
  end
end
