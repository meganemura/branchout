# frozen_string_literal: true

require "minitest/autorun"
require "concolic"

class TargetTest < Minitest::Test
  def setup
    @root = File.expand_path("..", __dir__)
  end

  def test_magic_literal_and_int_type
    target = Concolic::Target.parse(File.join(@root, "test/fixtures/magic.rb"), "FixtureMagic.classify")
    assert_equal [:x], target.positional.map(&:name)
    assert_equal ["int"], target.positional.map(&:inferred_type)
    assert_includes target.literals.ints, 114514
    assert_equal "x == 114514", target.condition_text(:if, 5, 4, :then, 6, 6)
  end

  def test_call_graph_skips_uncalled_helpers
    target = Concolic::Target.parse(File.join(@root, "test/fixtures/call.rb"), "FixtureCall.entry")
    assert_equal [0, 10], target.literals.ints
    refute_includes target.literals.ints, 9
    assert target.covers_line?(5)
    assert target.covers_line?(13)
    refute target.covers_line?(21)
  end

  def test_case_infers_string_and_int
    target = Concolic::Target.parse(File.join(@root, "test/fixtures/branches.rb"), "FixtureBranches.demo")
    types = target.positional.map { |param| [param.name, param.inferred_type] }
    assert_equal [[:s, "string"], [:n, "int"]], types
  end

  def test_instance_method_entry
    target = Concolic::Target.parse(File.join(@root, "test/fixtures/box.rb"), "FixtureBox#parity")
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
    target = Concolic::Target.parse(path, "Foo::Bar.ping")
    assert_equal "Foo::Bar", target.const_name
    assert_includes target.literals.ints, 2
  ensure
    File.delete(path) if path && File.file?(path)
  end

  def test_bad_entry
    error = assert_raises(Concolic::Error) do
      Concolic::Target.parse(File.join(@root, "test/fixtures/magic.rb"), "nope")
    end
    assert_match(/bad entry/, error.message)
  end

  def test_type_override_length
    error = assert_raises(Concolic::Error) do
      Concolic::Target.parse(
        File.join(@root, "test/fixtures/arith.rb"),
        "FixtureArith.classify",
        type_overrides: ["int"]
      )
    end
    assert_match(/types length/, error.message)
  end
end
