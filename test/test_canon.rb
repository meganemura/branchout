# frozen_string_literal: true

require "minitest/autorun"
require "concolic"

class CanonTest < Minitest::Test
  def test_json_sorts_keys_and_escapes
    text = Concolic::Canon.json({ "b" => 1, "a" => "あ" })
    assert_equal '{"a":"\\u3042","b":1}', text
  end

  def test_float_spelling
    assert_equal "0.0", Concolic::Canon.format_float(0.0)
    assert_equal "0.0", Concolic::Canon.format_float(-0.0)
    assert_equal "1.0", Concolic::Canon.format_float(1.0)
    assert_equal "0.5", Concolic::Canon.format_float(0.5)
  end

  def test_pretty_is_stable
    body = { "z" => [1, { "b" => 2, "a" => nil }], "a" => true }
    assert_equal Concolic::Canon.pretty(body), Concolic::Canon.pretty(body)
    assert_includes Concolic::Canon.pretty(body), '"a": true'
  end

  def test_rng_stream
    rng = Concolic::Rng.new(1)
    assert_equal [16_807, 282_475_249, 1_622_650_073, 984_943_658, 1_144_108_930], 5.times.map { rng.next_int }
  end

  def test_rng_rejects_negative_seed
    assert_raises(Concolic::Error) { Concolic::Rng.new(-1) }
  end

  def test_input_normalizes_negative_zero_and_kwargs
    input = Concolic::Input.new(args: [-0.0, { "b" => 1, "a" => 2 }], kwargs: { flag: false })
    assert_equal '{"args":[0.0,{"a":2,"b":1}],"kwargs":{"flag":false}}', input.canonical
    assert_in_delta 5.0, input.weight, 0.001
  end

  def test_input_weight_prefers_zero
    zero = Concolic::Input.new(args: [0])
    minus = Concolic::Input.new(args: [-1])
    assert_operator zero.weight, :<, minus.weight
  end
end
