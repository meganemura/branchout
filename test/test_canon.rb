# frozen_string_literal: true

require "minitest/autorun"
require "branchout"

class CanonTest < Minitest::Test
  def test_json_sorts_keys_and_escapes
    text = Branchout::Canon.json({ "b" => 1, "a" => "あ" })
    assert_equal '{"a":"\\u3042","b":1}', text
  end

  def test_float_spelling
    assert_equal "0.0", Branchout::Canon.format_float(0.0)
    assert_equal "0.0", Branchout::Canon.format_float(-0.0)
    assert_equal "1.0", Branchout::Canon.format_float(1.0)
    assert_equal "0.5", Branchout::Canon.format_float(0.5)
  end

  def test_float_spelling_reads_back_as_the_same_float
    [0.1 + 0.2, 1.0000000000000002e+16, Float::MAX, -Float::MIN].each do |value|
      text = Branchout::Canon.format_float(value)
      assert_equal value, JSON.parse(text), text
      assert_equal value, Float(text), text
    end
  end

  def test_pretty_is_stable
    body = { "z" => [1, { "b" => 2, "a" => nil }], "a" => true }
    assert_equal Branchout::Canon.pretty(body), Branchout::Canon.pretty(body)
    assert_includes Branchout::Canon.pretty(body), '"a": true'
  end

  def test_rng_stream
    rng = Branchout::Rng.new(1)
    assert_equal [16_807, 282_475_249, 1_622_650_073, 984_943_658, 1_144_108_930], 5.times.map { rng.next_int }
  end

  def test_rng_rejects_negative_seed
    assert_raises(Branchout::Error) { Branchout::Rng.new(-1) }
  end

  def test_input_normalizes_negative_zero_and_kwargs
    input = Branchout::Input.new(args: [-0.0, { "b" => 1, "a" => 2 }], kwargs: { flag: false })
    assert_equal '{"args":[0.0,{"a":2,"b":1}],"kwargs":{"flag":false}}', input.canonical
    assert_in_delta 5.0, input.weight, 0.001
  end

  def test_input_freezes_its_own_strings_and_not_the_callers
    text = +"ab"
    input = Branchout::Input.new(args: [text])
    text << "c"
    assert_equal ["ab"], input.args
    assert input.args.first.frozen?
  end

  def test_input_weight_prefers_zero
    zero = Branchout::Input.new(args: [0])
    minus = Branchout::Input.new(args: [-1])
    assert_operator zero.weight, :<, minus.weight
  end

  def test_pretty_layout
    body = { "b" => [1, { "c" => [] }], "a" => {} }
    expected = "{\n  \"b\": [\n    1,\n    {\n      \"c\": []\n    }\n  ],\n  \"a\": {}\n}"
    assert_equal expected, Branchout::Canon.pretty(body)
  end

  def test_symbol_is_escaped_like_a_string
    assert_equal '"\\u3042"', Branchout::Canon.json(:"\u3042")
  end

  def test_rng_rejects_an_empty_range
    error = assert_raises(Branchout::Error) { Branchout::Rng.new(1).rand_inclusive(1, 0) }
    assert_equal "empty range 1..0", error.message
  end

  def test_input_weight_counts_nesting_kwargs_and_new
    receiver = Branchout::Input.new(args: [4])
    input = Branchout::Input.new(args: [[1, -2], "ab"], kwargs: { "k" => 3 }, receiver: receiver)
    assert_equal (2 + 1 + 2) + 2 + 3 + 4, input.weight
  end

  def test_input_freezes_nested_values_and_refuses_non_finite_floats
    input = Branchout::Input.new(args: [[[1]], { "a" => [2] }])
    assert input.args.first.first.frozen?
    assert input.args.last["a"].frozen?
    error = assert_raises(Branchout::Error) { Branchout::Input.new(args: [Float::NAN]) }
    assert_equal "non-finite float", error.message
  end
end
