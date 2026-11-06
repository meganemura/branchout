# frozen_string_literal: true

require "minitest/autorun"
require "branchout"

# The engine in process: which arms a run reports, which inputs it pins,
# and how it reads a loop. The fixture loads once, so every test shares it.
class EngineTest < Minitest::Test
  PATH = File.expand_path("fixtures/loops.rb", __dir__)

  def explore(entry, inputs = [], **options)
    Branchout::Engine.explore(target: PATH, entry: entry, user_inputs: inputs.map { |args| Branchout::Input.new(args: args) },
                              strategies: ["inputs"], random: 0, **options)
  end

  # An until loop whose condition held at once reached its decision: the
  # line ran though the body arm did not.
  def test_an_until_loop_not_entered_was_reached
    arm = explore("FixtureLoops.drain", [[0]]).frontier.first
    assert_equal ["until@5:4/body@6:6", "reached", [0]], [arm.id, arm.parent, arm.nearest.args]
  end

  # A condition that raised took no arm, so no input reached that if.
  def test_a_condition_that_raised_did_not_reach_its_if
    result = explore("FixtureLoops.sign", [[{}]])
    assert_equal [%w[not-reached not-reached], nil], [result.frontier.map(&:parent), result.frontier.first.nearest]
  end

  # A loop body taken more than once says how often.
  def test_a_path_counts_a_loop_body_taken_more_than_once
    assert_equal ["until@5:4/body@6:6*3"], explore("FixtureLoops.drain", [[3]]).covered.first.path
  end

  # With no input every arm is on the frontier, from the target's own table.
  def test_no_input_puts_every_arm_on_the_frontier
    result = explore("FixtureLoops.sign")
    assert_equal [[], ["if@12:4/else@15:6", "if@12:4/then@13:6"]], [result.covered, result.frontier.map(&:id)]
  end

  # A mutate input is pinned when it is the witness of an arm or raises,
  # and not when it adds neither.
  def test_mutate_inputs_are_pinned_for_an_arm_or_an_exception
    result = explore("FixtureLoops.pick", strategies: ["mutate"], mutate_cap: 64)
    pins = result.pins.map { |pin| [pin.input.args.first, pin.error&.class_name] }
    assert_equal [["", nil], ["abc", "ArgumentError"], ["abc1", "ArgumentError"]], pins
    assert_equal 5, result.executions
  end

  # A types override changes what mutate tries.
  def test_a_type_override_reaches_mutate
    plain = explore("FixtureLoops.pick", strategies: ["mutate"], mutate_cap: 64)
    typed = explore("FixtureLoops.pick", strategies: ["mutate"], mutate_cap: 64, type_overrides: ["int"])
    assert(plain.pins.all? { |pin| pin.input.args.first.is_a?(String) })
    assert(typed.pins.any? { |pin| pin.input.args.first.is_a?(Integer) })
  end
  Box = Struct.new(:n)

  # Two runs pin the same when each literal is equal and every other value
  # has the same class and shape. A Hash keeps its stable keys only when
  # some stay, and they are literals.
  def test_differing_names_what_two_runs_would_pin_apart
    differing = Branchout::Runner.method(:differing)
    assert_nil differing.(1, 1)
    assert_equal :whole, differing.(1, 2)
    assert_equal ["b"], differing.({ a: 1, b: 2 }, { a: 1, b: 3 })
    assert_equal :whole, differing.({ a: 1 }, { a: 2 })
    assert_equal :whole, differing.({ a: 1 }, { b: 1 })
    assert_equal :whole, differing.({ a: Object.new, b: 1 }, { a: Object.new, b: 2 })
    assert_equal :whole, differing.(1, { a: 1 })
    assert_nil differing.(Object.new, Object.new)
    assert_equal :whole, differing.(Object.new, Box.new(1))
    assert_equal :whole, differing.(Object.new, "x")
    assert_nil differing.([Object.new], [Object.new])
    assert_equal :whole, differing.([Object.new], [Object.new, Object.new])
    assert_equal :whole, differing.([Object.new, 1], [Object.new, 2])
    assert_nil differing.([{ k: Object.new }], [{ k: Object.new }])
    assert_equal :whole, differing.([{ k: Object.new }], [{ j: Object.new }])
    assert_equal :whole, differing.([{ k: Object.new, n: 1 }], [{ k: Object.new, n: 2 }])
    assert_nil differing.(Box.new(1), Box.new(1))
    assert_equal :whole, differing.(Box.new(1), Box.new(2))
  end
end
