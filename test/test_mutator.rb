# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "tmpdir"
require "branchout"
require_relative "support/cli"

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

  # A private helper compares the argument it gets, under its own name,
  # against a String or a constant.
  def test_a_helper_types_the_argument_it_receives_and_lends_its_literals
    target = Branchout::Target.parse(File.join(@root, "test/fixtures/ledger.rb"), "FixtureLedger#label")
    assert_equal [[:code, "string"], [:cents, "int"]], target.positional.map { |param| [param.name, param.inferred_type] }
    inputs = Branchout::Mutator.new(target, cap: 64).inputs.map(&:args)
    assert_includes inputs, ["closed", 0]
    assert_includes inputs, ["held", 0]
    assert_includes inputs, ["", 501]
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
      "inputs" => [[0, 1], { "args" => [2, 3], "kwargs" => {}, "note" => "the boundary the refund rule reads" }]
    }))
    inputs, types = Branchout::InputFile.load(path)
    assert_equal ["int", "int"], types
    assert_equal [[0, 1], [2, 3]], inputs.map(&:args)
    assert_equal Branchout::Input.new(args: [2, 3]).canonical, inputs[1].canonical
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

  # A block and Ruby source are read from the entry, and a mistake in
  # either names the entry once.
  def test_input_file_reads_a_block_and_names_the_entry_of_bad_ruby
    Dir.mktmpdir do |dir|
      path = File.join(dir, "inputs.json")
      File.write(path, JSON.generate({ "inputs" => [{ "args" => [{ "ruby" => "Loan.new(3)" }], "block" => "{ |a| a }" }] }))
      inputs, _types = Branchout::InputFile.load(path)
      assert_equal '{"args":[{"ruby":"Loan.new(3)"}],"block":"{ |a| a }","kwargs":{}}', inputs.first.canonical

      { { "args" => [{ "ruby" => "Loan.new(" }] } => "#{path} inputs[0] Ruby \"Loan.new(\" does not parse",
        { "args" => [1], "block" => "a" } => "#{path} inputs[0] block \"a\" is not a block such as \"{ |item| item.price > 2 }\"",
        { "args" => [], "new" => { "args" => [{ "ruby" => "(" }] } } => "#{path} inputs[0] new Ruby \"(\" does not parse",
        { "args" => [], "zzz" => 1 } => "#{path} inputs[0] has unknown keys: zzz" }.each do |entry, message|
        File.write(path, JSON.generate({ "inputs" => [entry] }))
        error = assert_raises(Branchout::Error) { Branchout::InputFile.load(path) }
        assert_equal message, error.message
      end
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
    "{\"inputs\": [], \"types\": [\"char\"]}" => "has an unknown type (int, float, string, array, hash, bool)",
    "{\"inputs\": [{\"args\": [], \"arg\": 1}]}" => "inputs[0] has unknown keys: arg",
    "{\"inputs\": [{\"note\": \"none\"}]}" => "inputs[0] is missing args; write \"args\": [] for a call with no arguments",
    "{\"inputs\": [1]}" => "inputs[0] is 1, not a call; write each call as an array of its arguments, such as [1]",
    "[\"0306406150\", \"abc\"]" => "inputs[0] is \"0306406150\", not a call; write each call as an array of its arguments, such as [\"0306406150\"]",
    "{\"inputs\": [{\"args\": [], \"new\": 1}]}" => "inputs[0] new is 1, not a call; write each call as an array of its arguments, such as [1]",
    "{\"inputs\": [null]}" => "inputs[0] is null, not a call; write each call as an array of its arguments, such as [null]",
    "{\"inputs\": [{\"before\": \"create(:part)\"}]}" => "inputs[0] before must be Ruby such as {\"ruby\": \"create(:part)\"}",
    "{\"inputs\": [{\"args\": [], \"new\": {\"args\": [], \"before\": {\"ruby\": \"1\"}}}]}" => "inputs[0] new has unknown keys: before",
    "{\"inputs\": [{\"args\": 1}]}" => "input args must be an array",
    "{\"inputs\": [{\"args\": [], \"kwargs\": 1}]}" => "input kwargs must be an object",
    "{\"inputs\": [{\"args\": [], \"setup\": {}}]}" => "inputs[0] setup must be an array",
    "{\"inputs\": [{\"args\": [], \"setup\": [[]]}]}" => "inputs[0] setup[0] must be an object",
    "{\"inputs\": [{\"args\": [], \"setup\": [{\"args\": []}]}]}" => "inputs[0] setup[0] is missing method",
    "{\"inputs\": [{\"args\": [], \"setup\": [{\"method\": \"a b\"}]}]}" => "inputs[0] setup[0] method \"a b\" is not a method name",
    "{\"inputs\": [{\"args\": [], \"setup\": [{\"method\": \"a\", \"new\": []}]}]}" => "inputs[0] setup[0] has unknown keys: new",
    "{\"inputs\": [{\"args\": [], \"new\": {\"args\": [], \"setup\": []}}]}" => "inputs[0] new has unknown keys: setup",
    "{\"inputs\": [{\"args\": [], \"pin_keys\": \"a\"}]}" => "inputs[0] pin_keys must be an array of key names",
    "{\"inputs\": [{\"args\": [], \"pin_keys\": [1]}]}" => "inputs[0] pin_keys must be an array of key names",
    "{\"inputs\": [{\"args\": [], \"pin_keys\": [\"\"]}]}" => "inputs[0] pin_keys must be an array of key names",
    "{\"inputs\": [{\"args\": [], \"new\": {\"args\": [], \"pin_keys\": []}}]}" => "inputs[0] new has unknown keys: pin_keys"
  }.freeze

  # An entry that says how to call the method, by its receiver, setup,
  # keywords, or block, calls it with no positional argument when it leaves
  # args out.
  def test_an_entry_that_leaves_out_args_passes_none
    [{"receiver" => {"ruby" => "build(:user)"}}, {"new" => {"args" => [1]}}, {"setup" => [{"method" => "open"}]},
     {"kwargs" => {"on" => 1}}, {"block" => "{ |x| x }"}, {"before" => {"ruby" => "create(:part)"}}].each do |entry|
      assert_equal [], Branchout::InputFile.parse_entry(entry, "inputs[0]").args, entry.inspect
    end
  end

  # An input prints as its args array only when it has nothing else, so
  # the report's line pastes back as the same entry.
  def test_an_input_prints_as_an_entry_when_it_has_more_than_args
    code = Branchout::Code.parse("create(:part)")
    assert_equal "[1]", Branchout::Input.new(args: [1]).text
    {
      { kwargs: { "a" => 1 } } => '{"args":[],"kwargs":{"a":1}}',
      { receiver: code } => '{"args":[],"receiver":{"ruby":"create(:part)"}}',
      { setup: [Branchout::Input::SetupCall.new("open", Branchout::Input.new(args: []))] } => '{"args":[],"setup":[{"args":[],"method":"open"}]}',
      { block: Branchout::Code.block("{ |x| x }") } => '{"args":[],"block":"{ |x| x }"}',
      { before: code } => '{"args":[],"before":{"ruby":"create(:part)"}}'
    }.each do |parts, text|
      input = Branchout::Input.new(args: [], **parts)
      assert_equal text, input.text
    end
    with_before = Branchout::Input.new(args: [1], before: code)
    assert_equal({ "args" => [1], "kwargs" => {}, "before" => code }, with_before.to_h)
    assert_equal 1 + "create(:part)".length, with_before.weight
  end

  # pin_keys belongs to the test, not to the call: it is kept apart from
  # the canonical input, and nil means "use --pin-keys".
  def test_input_file_reads_pin_keys
    Dir.mktmpdir do |dir|
      path = File.join(dir, "inputs.json")
      File.write(path, JSON.generate({ "inputs" => [{ "args" => [1], "pin_keys" => %w[tax total] }, { "args" => [2], "pin_keys" => [] }, [3]] }))
      inputs, _types = Branchout::InputFile.load(path)
      assert_equal [%w[tax total], [], nil], inputs.map(&:pin_keys)
      assert_equal '{"args":[1],"kwargs":{}}', inputs.first.canonical
      assert inputs.first.pin_keys.frozen?
    end
  end

  def test_input_file_reads_setup_steps
    Dir.mktmpdir do |dir|
      path = File.join(dir, "inputs.json")
      File.write(path, JSON.generate({ "inputs" => [
        { "args" => [], "setup" => [{ "method" => "add", "args" => [1], "kwargs" => { "price" => 2 } }, { "method" => "<<" }, { "method" => "empty?" }] },
        { "args" => [], "setup" => [] }
      ] }))
      inputs, _types = Branchout::InputFile.load(path)
      assert_equal '{"args":[],"kwargs":{},"setup":[{"args":[1],"kwargs":{"price":2},"method":"add"},' \
                   '{"args":[],"kwargs":{},"method":"<<"},{"args":[],"kwargs":{},"method":"empty?"}]}', inputs.first.canonical
      assert_equal "[]", inputs.last.text
      assert_equal 6, inputs.first.weight
    end
  end

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

  def test_a_bare_array_file_is_a_list_of_inputs_with_no_types
    Dir.mktmpdir do |dir|
      path = File.join(dir, "inputs.json")
      File.write(path, JSON.generate([[1], { "args" => [2] }]))
      inputs, types = Branchout::InputFile.load(path)
      assert_nil types
      assert_equal [[1], [2]], inputs.map(&:args)
    end
  end

  def test_a_false_default_is_a_flag_both_strategies_flip
    Dir.mktmpdir do |dir|
      path = File.join(dir, "t.rb")
      File.write(path, "module T\n  def self.f(flag = false) = flag ? :on : :off\nend\n")
      target = Branchout::Target.parse(path, "T.f")
      assert_equal [[false], [true]], Branchout::Mutator.new(target, cap: 8).inputs.map(&:args)
      samples = Branchout::Sampler.new(target, seed: 1, count: 16).inputs.map(&:args)
      assert_equal [[false], [true]], samples.uniq.sort_by(&:inspect)
    end
  end
  # A bool given by the types list with no default starts at false, the
  # value the other parameters' mutations hold it at.
  def test_a_typed_bool_with_no_default_starts_false
    Dir.mktmpdir do |dir|
      path = File.join(dir, "t.rb")
      File.write(path, "module T\n  def self.f(n, flag) = flag && n > 1 ? :big : :small\nend\n")
      target = Branchout::Target.parse(path, "T.f", type_overrides: %w[int bool])
      inputs = Branchout::Mutator.new(target, cap: 64).inputs.map(&:args)
      assert_includes inputs, [2, false]
      assert_includes inputs, [0, true]
      assert(inputs.all? { |_n, flag| [true, false].include?(flag) }, inputs.inspect)
    end
  end

  def test_mutate_and_random_fill_the_constructor_arguments
    target = Branchout::Target.parse(File.join(@root, "test/fixtures/account.rb"), "FixtureAccount#withdraw")
    assert_equal [[:balance, "int"], [:limit, "int"]], target.constructor.map { |param| [param.name, param.inferred_type] }
    mutated = Branchout::Mutator.new(target, cap: 256).inputs
    assert(mutated.all? { |input| input.receiver&.args&.length == 1 })
    assert_includes mutated.map { |input| [input.args, input.receiver.args] }, [[0], [-1]]
    sampled = Branchout::Sampler.new(target, seed: 1, count: 4).inputs
    assert(sampled.all? { |input| input.receiver.args.first.between?(-3, 12) && input.receiver.kwargs.empty? })

    singleton = Branchout::Target.parse(File.join(@root, "test/fixtures/magic.rb"), "FixtureMagic.classify")
    assert_empty singleton.constructor
    assert(Branchout::Mutator.new(singleton, cap: 8).inputs.none?(&:receiver))
  end

  def test_mutate_covers_an_account_with_no_inputs_file
    Dir.mktmpdir do |dir|
      stdout, stderr, status = CLIProcess.run(
        "explore", "test/fixtures/account.rb", "FixtureAccount#withdraw",
        "--strategy", "mutate,random", "--seed", "1", chdir: @root
      )
      assert status.success?, stderr
      assert_includes stdout, "covered: 2 of 2 arms"
    end
  end

  # The pools the README promises: neighbors of each literal, the fixed
  # small values, and the product of two leading numeric slots.
  def test_pools_hold_the_documented_values
    Dir.mktmpdir do |dir|
      path = File.join(dir, "t.rb")
      File.write(path, "module T\n  def self.f(x, y = 2.5, s = \"ab\") = x == 4 || s == \"cd\"\n" \
                       "  def self.g(s, x) = s == \"cd\" || x == 4\nend\n")
      target = Branchout::Target.parse(path, "T.f")
      mutator = Branchout::Mutator.new(target, cap: 1000)
      x, y, s = target.positional
      assert_equal [-1, 0, 1, 3, 4, 5], mutator.pool_for(x)
      assert_equal [-2.0, -1.0, 0.0, 1.0, 1.5, 2.0, 2.5, 3.0, 3.5, 4.0, 5.0], mutator.pool_for(y)
      assert_equal ["", "a", "ab", "ab1", "c", "cd", "cd1"], mutator.pool_for(s)
      inputs = mutator.inputs.map(&:args)
      assert_includes inputs, [0, 2.5, "ab"]
      assert_includes inputs, [4, 3.5, "ab"]
      assert_equal 22 + (6 * 11) - (6 + 11 - 1), inputs.length
      assert_empty Branchout::Mutator.new(target, cap: 0).inputs

      other = Branchout::Target.parse(path, "T.g")
      assert_equal 1 + 4 + 5, Branchout::Mutator.new(other, cap: 1000).inputs.length
    end
  end
end
