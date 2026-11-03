# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "open3"
require "tmpdir"
require "branchout"

class TargetTest < Minitest::Test
  def setup
    @root = File.expand_path("..", __dir__)
  end

  def test_magic_literal_and_int_type
    target = Branchout::Target.parse(File.join(@root, "test/fixtures/magic.rb"), "FixtureMagic.classify")
    assert_equal [:x], target.positional.map(&:name)
    assert_equal ["int"], target.positional.map(&:inferred_type)
    assert_includes target.literals.ints, 114514
    assert_equal "x == 114514", target.condition_text(:if, 5, 4, :then, 6, 6)
  end

  def test_call_graph_skips_uncalled_helpers
    target = Branchout::Target.parse(File.join(@root, "test/fixtures/call.rb"), "FixtureCall.entry")
    assert_equal [0, 10], target.literals.ints
    refute_includes target.literals.ints, 9
    assert target.covers_line?(5)
    assert target.covers_line?(13)
    refute target.covers_line?(21)
  end

  def test_case_infers_string_and_int
    target = Branchout::Target.parse(File.join(@root, "test/fixtures/branches.rb"), "FixtureBranches.demo")
    types = target.positional.map { |param| [param.name, param.inferred_type] }
    assert_equal [[:s, "string"], [:n, "int"]], types
  end

  def test_instance_method_entry
    target = Branchout::Target.parse(File.join(@root, "test/fixtures/box.rb"), "FixtureBox#parity")
    refute target.singleton
    assert_equal :parity, target.method_name
    assert_equal "int", target.positional.first.inferred_type
  end

  def test_nested_const_path
    path = File.join(@root, "test/fixtures/nested.rb")
    File.write(path, <<~RUBY)
      # frozen_string_literal: true
      module Foo
        module Bar
          def self.ping(x)
            if x == 2
              :yes
            else
              :no
            end
          end
        end
      end
    RUBY
    target = Branchout::Target.parse(path, "Foo::Bar.ping")
    assert_equal "Foo::Bar", target.const_name
    assert_includes target.literals.ints, 2
  ensure
    File.delete(path) if path && File.file?(path)
  end

  def test_bad_entry
    error = assert_raises(Branchout::Error) do
      Branchout::Target.parse(File.join(@root, "test/fixtures/magic.rb"), "nope")
    end
    assert_match(/bad entry/, error.message)
  end

  def test_module_function_methods_are_class_methods_too
    path = File.join(@root, "test/fixtures/helpers.rb")
    target = Branchout::Target.parse(path, "FixtureHelpers.sign")
    assert target.covers_line?(13)
    assert Branchout::Target.parse(path, "FixtureHelpers#sign")
    assert_includes Branchout::Target.parse(path, "FixtureNamed.twice").literals.ints, 3
    error = assert_raises(Branchout::Error) { Branchout::Target.parse(path, "FixtureNamed.nope") }
    assert_match(/cannot find FixtureNamed.nope/, error.message)
  end

  def test_extend_self_makes_every_def_a_class_method_once
    Dir.mktmpdir do |dir|
      path = File.join(dir, "t.rb")
      File.write(path, "module T\n  def f(x) = g(x)\n  module_function\n  extend self\n  def g(x) = x > 1\nend\n")
      assert Branchout::Target.parse(path, "T.f").covers_line?(5)
      assert Branchout::Target.parse(path, "T.g")
    end
  end

  # Each source is the body of module T; the type is inferred for the first
  # positional parameter of T.f. Ties go string, hash, array, float, int.
  TYPE_CASES = {
    'def self.f(s) = s.include?("a")' => "string",
    "def self.f(h) = h.keys" => "hash",
    "def self.f(a) = a.first" => "array",
    "def self.f(x) = x + 1.5" => "float",
    "def self.f(x) = x + 1" => "int",
    'def self.f(x = "a") = x' => "string",
    "def self.f(x = 2.0) = x" => "float",
    "def self.f(x) = x" => "int",
    "def self.f(x = []) = x" => "array",
    "def self.f(x = [1, \"a\"]) = x" => "array",
    "def self.f(x = {}) = x" => "hash",
    "def self.f(x = { a: 1 }) = x" => "hash",
    "def self.f(x = false) = x" => "bool",
    "def self.f(x = true) = x" => "bool",
    'def self.f(s) = s.include?("a") || s == 1' => "string",
    'def self.f(s) = s.include?("a") || s.keys' => "string",
    "def self.f(h) = h.keys || h.first" => "hash",
    "def self.f(a) = a.first || a + 1" => "array",
    "def self.f(x) = x + 1.5 || x + 1" => "float",
    'def self.f(s) = s.include?("a") || s.keys || s.fetch(1)' => "hash",
    'def self.f(h) = h.keys || h.first || h.last' => "array",
    'def self.f(x) = x == "a"' => "string",
    "def self.f(x) = 1.5 < x" => "float",
    'def self.f(x) = "a" == x' => "string",
    "def self.f(x) = 1 + x" => "int",
    'def self.f(s) = s.count("a")' => "string",
    "def self.f(a) = a.count" => "int",
    "def self.f(x)\n  case x\n  when 1.5 then 1\n  end\nend" => "float",
    "def self.f(x)\n  case x\n  when \"a\" then 1\n  end\nend" => "string",
    "def self.f(x)\n  case x\n  when 1 then 1\n  end\nend" => "int",
    "def self.f(x, y) = g(x) || x.first\ndef self.g(x) = x.include?(\"a\") || x.strip" => "string",
    %q{def self.f(s) = s.include?("a") || s.first} => "string",
    %q{def self.f(s) = s.include?("a") || s + 1.5} => "string",
    "def self.f(h) = h.keys || h + 1" => "hash",
    "def self.f(h) = h.keys || h + 1.5" => "hash",
    "def self.f(a) = a.first || a + 1.5" => "array",
    "def self.f(a) = a.first || a + 1 || a - 1" => "int",
    "def self.f(x) = x + 1.5 || x + 1 || x - 1" => "int",
    %q{def self.f(s) = s.include?("a") || s.first || s.last} => "array",
    %q{def self.f(s) = s.include?("a") || s + 1 || s - 1} => "int",
    "def self.f(h) = h.keys || h + 1.5 || h - 1.5" => "float"
  }.freeze

  def test_type_inference_table
    Dir.mktmpdir do |dir|
      path = File.join(dir, "t.rb")
      TYPE_CASES.each do |source, type|
        File.write(path, "module T\n#{source}\nend\n")
        assert_equal type, Branchout::Target.parse(path, "T.f").positional.first.inferred_type, source
      end
    end
  end

  def test_parameter_kinds_defaults_and_types
    Dir.mktmpdir do |dir|
      path = File.join(dir, "t.rb")
      File.write(path, "module T\n  def self.f(a, b = 2, *rest, k:, j: 1.5, s: \"x\") = a\nend\n")
      params = Branchout::Target.parse(path, "T.f").parameters
      assert_equal [[:req, :a, nil, "int"], [:opt, :b, 2, "int"], [:rest, :rest, nil, "array"],
                    [:keyreq, :k, nil, "int"], [:key, :j, 1.5, "float"], [:key, :s, "x", "string"]],
                   params.map { |param| [param.kind, param.name, param.default, param.inferred_type] }
      error = assert_raises(Branchout::Error) { Branchout::Target.parse(File.join(dir, "nope.rb"), "T.f") }
      assert_equal "target file not found: #{File.join(dir, "nope.rb")}", error.message
      File.write(path, "module T\n  def self.f(\nend\n")
      error = assert_raises(Branchout::Error) { Branchout::Target.parse(path, "T.f") }
      assert_match(/\Afailed to parse .*t\.rb: /, error.message)
    end
  end

  def test_condition_text_for_each_kind_of_decision
    expected = {
      "pick" => { "case@5:4/else@10:6" => "case x else", "case@5:4/when@6:19" => "when 1, 2 then :low",
                  "case@5:4/when@8:6" => "when 3" },
      "shape" => { "case@15:4/in@16:34" => "in Integer => n if n > 5 then :big",
                   "case@15:4/in@17:20" => "in Integer then :int", "case@15:4/else@18:9" => "case x else" },
      "bare" => { "case@23:4/when@24:20" => "when x > 1 then :gt", "case@23:4/else@23:4" => "case else" },
      "long" => { "if@29:4/then@29:4" => "x == 1 && x != 22222222222222222222 && x != 33333333333333333333 && " \
                                         "x != 44444444444444444444 && x != 55555555555555555555 && " \
                                         "x != 66666666666666666666 && x ..." },
      "loop" => { "while@35:4/body@35:4" => "x > 0" }
    }
    Dir.mktmpdir do |dir|
      inputs = File.join(dir, "inputs.json")
      File.write(inputs, '{"inputs": [[0]]}')
      expected.each do |name, conds|
        stdout, stderr, status = Open3.capture3(
          RbConfig.ruby, File.join(@root, "bin/branchout"), "explore", "test/fixtures/conds.rb", "FixtureConds.#{name}",
          "--inputs", inputs, "--strategy", "inputs", "--random", "0", "--json", chdir: @root
        )
        assert status.success?, stderr
        report = JSON.parse(stdout)
        arms = (report["covered"] + report["frontier"]).to_h { |arm| [arm["id"], arm["cond"]] }
        conds.each { |id, cond| assert_equal cond, arms[id], "#{name} #{id}" }
      end
    end
  end

  def test_type_override_length
    error = assert_raises(Branchout::Error) do
      Branchout::Target.parse(
        File.join(@root, "test/fixtures/arith.rb"),
        "FixtureArith.classify",
        type_overrides: ["int"]
      )
    end
    assert_match(/types length/, error.message)
  end

  def parse_source(source, entry, **options)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "t.rb")
      File.write(path, source)
      yield Branchout::Target.parse(path, entry, **options), path
    end
  end

  def test_a_duplicate_definition_is_refused
    parse_source("module T\n  def self.g = 1\nend\n", "T.g") { |target| assert_equal "T.g", target.entry }
    error = assert_raises(Branchout::Error) do
      parse_source("module T\n  def self.f = 1\n  def self.f = 2\nend\n", "T.f") { flunk }
    end
    assert_match(/\Aduplicate T\.f in /, error.message)
  end

  def test_mutual_recursion_is_parsed_once
    parse_source("module T\n  def self.f(x) = x > 0 ? g(x - 1) : 0\n  def self.g(x) = x > 5 ? f(x) : 1\nend\n", "T.f") do |target|
      assert_equal [2..2, 3..3], target.ranges
      assert_equal [0, 1, 5], target.literals.ints
    end
  end

  def test_literals_include_defaults_once_and_sorted
    source = "module T\n  def self.f(x = 77, s = \"z\") = x == 3 || x == 1 || x == 3 || x == 2.5 || x == 0.5 || s == \"a\" || s == \"a\"\nend\n"
    parse_source(source, "T.f") do |target|
      assert_equal [1, 3, 77], target.literals.ints
      assert_equal [0.5, 2.5], target.literals.floats
      assert_equal %w[a z], target.literals.strings
    end
  end

  def test_a_method_with_no_parameters_has_none
    parse_source("module T\n  def self.f = 1\nend\n", "T.f") { |target| assert_empty target.parameters }
  end

  def test_compact_module_paths_and_singleton_class_methods
    parse_source("module Foo::Bar\n  class << self\n    def f(x) = x > 1\n  end\nend\nmodule Empty\nend\n", "Foo::Bar.f") do |target|
      assert target.covers_line?(3)
    end
  end

  def test_a_same_named_method_on_another_receiver_is_not_followed
    parse_source("module T\n  def self.f(x) = x.g\n  def self.g = 2 > 1\nend\n", "T.f") do |target|
      refute target.covers_line?(3)
      assert_empty target.literals.ints
    end
  end

  # An entry inherited from a superclass in the same file is found there,
  # and a call it makes reaches the subclass's override, as at run time.
  def test_an_inherited_entry_follows_the_subclass_overrides
    source = <<~RUBY
      module M
        class Base
          def lend(n) = allowed?(n) ? :lent : :kept
          def self.open(n) = n > 2
          private def allowed?(n) = n < 3
        end
        class Open < Base
          private def allowed?(n) = n < 10
        end
      end
      class Wide < M::Open
      end
    RUBY
    parse_source(source, "M::Open#lend") do |target|
      assert_equal [3..3, 8..8], target.ranges
      assert_equal [10], target.literals.ints
    end
    parse_source(source, "Wide#lend") { |target| assert_equal [3..3, 8..8], target.ranges }
    parse_source(source, "Wide.open") { |target| assert_equal [4..4], target.ranges }
  end

  # Prism parses superclasses that Ruby would refuse to load, so a cycle in
  # them must still end the walk.
  def test_a_superclass_cycle_ends
    Timeout.timeout(5) do
      parse_source("class A < B\nend\nclass B < A\n  def f = 1\nend\n", "A#f") { |target| assert_equal [4..4], target.ranges }
      error = assert_raises(Branchout::Error) { parse_source("class A < B\nend\nclass B < A\nend\n", "A#f") { flunk } }
      assert_match(/\Acannot find A#f/, error.message)
    end
  end

  def test_a_nested_def_is_not_part_of_the_method
    parse_source("module T\n  def self.f(x)\n    def self.g = 9\n    x > 1\n  end\nend\n", "T.f") do |target|
      assert_equal [1], target.literals.ints
    end
  end

  def test_condition_text_without_a_decision_node_is_the_source_line
    parse_source("module T\n  def self.f(x) =\n    x&.size\nend\n", "T.f") do |target|
      assert_equal "x&.size", target.condition_text(:"&.", 3, 4, :then, 3, 4)
    end
    exact = "x == #{"1" * 155}"
    parse_source("module T\n  def self.f(x) = #{exact} ? 1 : 2\nend\n", "T.f") do |target|
      assert_equal exact, target.condition_text(:if, 2, 18, :then, 2, 18)
    end
  end

  def test_display_path_is_relative_inside_the_working_directory
    assert_equal "lib/x.rb", Branchout::Target.display_path(File.join(Dir.pwd, "lib/x.rb"))
    assert_equal "/elsewhere/x.rb", Branchout::Target.display_path("/elsewhere/x.rb")
  end

  def test_type_overrides_apply_to_positional_parameters_only
    parse_source("module T\n  def self.f(a, b = 1, *rest, k:) = a\nend\n", "T.f", type_overrides: %w[string float]) do |target|
      assert_equal [%w[a string], %w[b float], %w[rest array], %w[k int]],
                   target.parameters.map { |param| [param.name.to_s, param.inferred_type] }
    end
  end
end
