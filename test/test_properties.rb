# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "branchout"

if Gem::Version.new(RUBY_VERSION) < Gem::Version.new("3.4")
  class PropertyTest < Minitest::Test
    def test_properties_need_ruby_3_4
      skip "hegeltest needs Ruby 3.4 or newer"
    end
  end
  return
end

require "hegel"

class PropertyTest < Minitest::Test
  include Hegel::Syntax::Methods

  ROOT = File.expand_path("..", __dir__)

  def json_values
    leaf = one_of(
      just(nil), booleans,
      integers(min_value: -10**6, max_value: 10**6),
      floats(allow_nan: false, allow_infinity: false),
      text(max_size: 4)
    )
    recursive(leaf, max_leaves: 8) do |inner|
      one_of(arrays(inner, max_size: 3), hashes(text(max_size: 3), inner, max_size: 3))
    end
  end

  def draw_input(tc, receiver: true)
    args = tc.draw(arrays(json_values, max_size: 3))
    kwargs = tc.draw(hashes(text(min_size: 1, max_size: 3), json_values, max_size: 2))
    new_args = receiver && tc.draw(booleans) ? draw_input(tc, receiver: false) : nil
    names = sampled_from(%w[add << reset! empty? limit=])
    setup = receiver ? tc.draw(arrays(names, max_size: 2)) : []
    setup = setup.map { |name| Branchout::Input::SetupCall.new(name, draw_input(tc, receiver: false)) }
    Branchout::Input.new(args: args, kwargs: kwargs, receiver: new_args, setup: setup)
  end

  def test_canonical_json_parses_back_to_the_value
    Hegel.test do |tc|
      value = Branchout::Input.new(args: [tc.draw(json_values)]).args.first
      assert_equal [value], [JSON.parse(Branchout::Canon.json(value))]
    end
  end

  def test_an_emitted_literal_evaluates_to_the_value
    Hegel.test do |tc|
      value = Branchout::Input.new(args: [tc.draw(json_values)]).args.first
      assert_equal [value], [eval(Branchout::Emitters::Support.ruby_literal(value))] # rubocop:disable Security/Eval
      assert_equal [value], [eval(Branchout::Emitters::Support.ruby_literal(value, mutable: true))] # rubocop:disable Security/Eval
    end
  end

  def test_the_reported_input_pastes_back_as_the_same_input
    Hegel.test do |tc|
      input = draw_input(tc)
      entry = JSON.parse(input.text)
      assert_equal input.canonical, Branchout::InputFile.parse_entry(entry, "entry").canonical
    end
  end

  def test_emitted_test_names_are_unique_methods_and_kept_when_inputs_are_added
    Hegel.test do |tc|
      pins = tc.draw(arrays(booleans, min_size: 1, max_size: 6)).map do |raises|
        error = raises ? Branchout::Runner::ExceptionInfo.new(class_name: "Foo::BarError") : nil
        Branchout::Engine::Pin.new(input: draw_input(tc), value: tc.draw(json_values), error: error, arm_ids: [])
      end
      pins = pins.uniq { |pin| pin.input.canonical }
      names = Branchout::Emitters::Support.test_names(pins)
      assert_equal names.uniq, names
      assert(names.all? { |name| name.match?(/\Atest_[a-z0-9_]+\z/) && name.length <= 90 })
      kept = tc.draw(arrays(sampled_from((0...pins.length).to_a), max_size: pins.length)).uniq.sort
      assert_equal kept.map { |index| names[index] }, Branchout::Emitters::Support.test_names(kept.map { |index| pins[index] })
    end
  end

  def test_keyword_order_does_not_change_an_input
    Hegel.test do |tc|
      kwargs = tc.draw(hashes(text(min_size: 1, max_size: 3), integers, max_size: 4))
      shuffled = tc.draw(permutations(kwargs.to_a)).to_h
      assert_equal Branchout::Input.new(args: [], kwargs: kwargs).canonical,
                   Branchout::Input.new(args: [], kwargs: shuffled).canonical
    end
  end

  def test_random_samples_stay_in_range_and_repeat_for_a_seed
    Hegel.test do |tc|
      seed = tc.draw(integers(min_value: 0, max_value: 2**40))
      low = tc.draw(integers(min_value: -1000, max_value: 1000))
      high = tc.draw(integers(min_value: low, max_value: low + 1000))
      first = Branchout::Rng.new(seed)
      second = Branchout::Rng.new(seed)
      samples = Array.new(8) { first.rand_inclusive(low, high) }
      assert(samples.all? { |sample| sample.between?(low, high) })
      assert_equal samples, Array.new(8) { second.rand_inclusive(low, high) }
    end
  end

  def test_the_report_does_not_depend_on_input_order_or_repeats
    target = File.join(ROOT, "examples/hidden_bug.rb")
    Hegel.test do |tc|
      pairs = tc.draw(arrays(arrays(integers(min_value: -2, max_value: 30), min_size: 2, max_size: 2), min_size: 1, max_size: 6))
      reordered = tc.draw(permutations(pairs + pairs.first(1)))
      reports = [pairs, reordered].map do |list|
        result = Branchout::Engine.explore(
          target: target, entry: "HiddenBug.scale",
          user_inputs: list.map { |args| Branchout::Input.new(args: args) },
          strategies: ["inputs"], random: 0
        )
        [Branchout::Report.text(result), Branchout::Report.json(result)]
      end
      assert_equal reports[0], reports[1]
    end
  end
end
