# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "json"
require "tmpdir"
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
    code = sampled_from(["Loan.new(3)", "KeyError.new(\"sku\")", "{\"ruby\" => \"3.4\"}", "[{sku: \"B\"}]", "{x: 1, \"x\" => 2}"]).map { |source| { "ruby" => source } }
    args = tc.draw(arrays(one_of(json_values, code), max_size: 3))
    kwargs = tc.draw(hashes(text(min_size: 1, max_size: 3), json_values, max_size: 2))
    new_args = receiver && tc.draw(booleans) ? draw_input(tc, receiver: false) : nil
    names = sampled_from(%w[add << reset! empty? limit=])
    setup = receiver ? tc.draw(arrays(names, max_size: 2)) : []
    setup = setup.map { |name| Branchout::Input::SetupCall.new(name, draw_input(tc, receiver: false)) }
    block = Branchout::Code.block("{ |item| item * 2 }") if receiver && tc.draw(booleans)
    Branchout::Input.new(args: args, kwargs: kwargs, receiver: new_args, setup: setup, block: block)
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
      assert_equal [value], [eval(Branchout::Emitters::Support.ruby_literal(value, thawed: true))] # rubocop:disable Security/Eval
    end
  end

  def test_an_emitted_hash_with_symbol_keys_evaluates_to_the_value
    Hegel.test do |tc|
      value = tc.draw(hashes(text(max_size: 4), json_values, max_size: 3)).transform_keys(&:to_sym)
      assert_equal [value], [eval(Branchout::Emitters::Support.ruby_literal(value))] # rubocop:disable Security/Eval
    end
  end

  def test_the_reported_input_pastes_back_as_the_same_input
    Hegel.test do |tc|
      input = draw_input(tc)
      entry = JSON.parse(input.text)
      assert_equal input.canonical, Branchout::InputFile.parse_entry(entry, "entry").canonical
    end
  end

  # A message that quotes frames matches its pattern with each label in
  # either Ruby's form, and stops matching when any other part changes.
  def test_a_frame_pattern_accepts_either_label_and_nothing_else
    Hegel.test do |tc|
      words = text(max_size: 6).filter { |part| !part.match?(/[`'\n]/) }
      parts = tc.draw(arrays(words, min_size: 1, max_size: 3))
      labels = parts.map { |part| ["'Box.#{part}'", "`#{part}'"] }
      frames = parts.each_with_index.map { |_, index| "lib/x.rb:#{index + 1}:in " }
      raw = frames.zip(labels).map { |frame, (new_label, _)| "#{frame}#{new_label}" }.join(" / ")
      pattern = Regexp.new(Branchout::Runner::ExceptionInfo.frame_pattern("raised: #{raw}"))
      old = frames.zip(labels).map { |frame, (_, old_label)| "#{frame}#{old_label}" }.join(" / ")
      assert_match pattern, "raised: #{raw}"
      assert_match pattern, "raised: #{old}"
      refute_match pattern, "raised: #{raw.sub("lib/x.rb:1:", "lib/x.rb:9:")}"
      refute_match pattern, "Raised: #{raw}"
    end
  end

  # The names depend on the set of inputs, not on their order, so the same
  # inputs file gives the same names.
  def test_emitted_test_names_are_unique_methods_whatever_the_input_order
    Hegel.test do |tc|
      pins = tc.draw(arrays(booleans, min_size: 1, max_size: 6)).map do |raises|
        error = raises ? Branchout::Runner::ExceptionInfo.new(class_name: "Foo::BarError") : nil
        Branchout::Engine::Pin.new(input: draw_input(tc), value: tc.draw(json_values), error: error, covers: [])
      end
      pins = pins.uniq { |pin| pin.input.canonical }
      names = Branchout::Emitters::Support.test_names(pins)
      assert_equal names.uniq, names
      assert(names.all? { |name| name.match?(/\Atest_[a-z0-9_]+\z/) && !name.include?("__") && name.length <= 104 }, names.inspect)
      pins.zip(names) do |pin, name|
        next if pin.error

        assert_equal pin.value.nil?, name.match?(/_returns_nil(_\h{6})?(_\d+)?\z/), "#{name} for #{pin.value.inspect}"
      end
      order = tc.draw(permutations((0...pins.length).to_a))
      assert_equal order.map { |index| names[index] }, Branchout::Emitters::Support.test_names(order.map { |index| pins[index] })
    end
  end

  # Inputs that share every word of their name are named by the leaves that
  # differ between them, and a digest stays only where that still collides.
  def test_sibling_names_carry_a_digest_only_when_they_still_collide
    Hegel.test do |tc|
      statuses = tc.draw(arrays(sampled_from(%w[fail pass timeout error skip]), min_size: 2, max_size: 5, unique: true))
      pins = statuses.map do |status|
        doc = { "tests" => [{ "id" => "t1", "head" => { "status" => status } }] }
        Branchout::Engine::Pin.new(input: Branchout::Input.new(args: [doc]), value: 1, error: nil, covers: [])
      end
      names = Branchout::Emitters::Support.test_names(pins)
      assert_equal statuses.map { |status| "test_status_#{status}_returns_1" }, names
    end
  end

  # Every word of a name is a whole word of the input or the outcome: the
  # cut falls between words, a blank argument leaves the word blank, and
  # an empty one the word empty.
  def test_emitted_test_names_cut_between_words
    vocabulary = %w[apple discount cents due lines qty sku raised ok]
    shapes = %w[test returns raises hash array of and empty blank nil true false foo bar error]
    word = one_of(sampled_from(vocabulary), sampled_from(["", " ", "  "]), integers(min_value: -99, max_value: 999))
    value = recursive(word, max_leaves: 6) do |inner|
      one_of(arrays(inner, max_size: 3), hashes(sampled_from(vocabulary), inner, max_size: 3))
    end
    Hegel.test do |tc|
      args = tc.draw(arrays(one_of(word, sampled_from([[], {}])), min_size: 1, max_size: 6))
      error = tc.draw(booleans) ? Branchout::Runner::ExceptionInfo.new(class_name: "Foo::BarError") : nil
      pin = Branchout::Engine::Pin.new(input: Branchout::Input.new(args: args), value: tc.draw(value), error: error, covers: [])
      name = Branchout::Emitters::Support.test_names([pin]).first
      words = name.split(/_+/)
      words.each { |part| assert(vocabulary.include?(part) || shapes.include?(part) || part.match?(/\A(neg)?\d+\z/), name) }
      first = args.first
      expected = first.is_a?(Integer) ? first.to_s.sub("-", "neg") : { "" => "empty", " " => "blank", "  " => "blank", [] => "empty", {} => "empty" }.fetch(first, first)
      assert_equal expected, words[1], name
    end
  end

  # A Hash outcome names its first keys whole and in order, each after the
  # first after "and".
  def test_a_hash_outcome_names_its_first_keys_whole
    keys = sampled_from(%w[due line_items discount_cents a_b_c qty])
    Hegel.test do |tc|
      value = tc.draw(hashes(keys, integers(min_value: 0, max_value: 9), min_size: 1, max_size: 5))
      pin = Branchout::Engine::Pin.new(input: Branchout::Input.new(args: [1]), value: value, error: nil, covers: [])
      name = Branchout::Emitters::Support.test_names([pin]).first
      named = name.delete_prefix("test_1_returns_hash_").split("_and_")
      refute_empty named, name
      assert_equal value.keys.first(named.length), named, name
    end
  end

  # A minitest name and an RSpec description name the same leaves of a
  # Hash outcome, in the same order.
  def test_both_formats_name_the_same_leaves_of_a_hash_outcome
    keys = sampled_from(%w[due tax qty sku total lines] + %i[due tax qty sku total lines])
    Hegel.test do |tc|
      values = tc.draw(arrays(hashes(keys, integers(min_value: 0, max_value: 3), min_size: 1, max_size: 4), min_size: 1, max_size: 5))
      pins = values.each_with_index.map do |value, index|
        Branchout::Engine::Pin.new(input: Branchout::Input.new(args: [index]), value: value, error: nil, covers: [])
      end
      names = Branchout::Emitters::Support.test_names(pins)
      outcomes = Branchout::Emitters::Support.outcomes(pins).values
      names.zip(outcomes) do |name, outcome|
        entry = /(?:\Areturns |, )(?:([a-z]+):|"([a-z]+)" =>) /
        next unless outcome.match?(/\Areturns (?:[a-z]+:|"[a-z]+" =>) /)

        assert_equal outcome.scan(entry).flatten.compact, name.split("_returns").last.scan(/(?:\A_|_and_)([a-z]+)_\d/).flatten, "#{name} / #{outcome}"
      end
    end
  end

  # An emitted spec parses, no two examples or contexts of one group share
  # a text, no text is over 80 characters, and no fact or outcome starts
  # at a bare position or key ([0] is 1, ["status"] is 1) without what
  # holds it, so rspec --format documentation tells every input apart in
  # lines a reader can scan.
  def test_an_emitted_spec_parses_and_tells_its_examples_apart
    param = Struct.new(:name)
    Hegel.test do |tc|
      singleton = tc.draw(booleans)
      target = Struct.new(:singleton, :const_name, :method_name, :entry, :display_path, :path, :parameters, :positional)
                     .new(singleton, "Foo::Bar", :run, "Foo::Bar#run", "lib/bar.rb", File.join(ROOT, "lib/bar.rb"),
                          [], [param.new(:a), param.new(:b)])
      # Inputs that all pass one argument are named apart by the path inside it.
      one_argument = tc.draw(booleans)
      pins = tc.draw(arrays(booleans, min_size: 1, max_size: 6)).map do |raises|
        error = raises ? Branchout::Runner::ExceptionInfo.new(class_name: "Foo::BarError") : nil
        input = draw_input(tc, receiver: !singleton)
        input = Branchout::Input.new(args: [tc.draw(json_values)], receiver: input.receiver, setup: input.setup, block: input.block) if one_argument
        Branchout::Engine::Pin.new(input: input, value: tc.draw(json_values), error: error, covers: [])
      end
      pins = pins.uniq { |pin| pin.input.canonical }
      result = Branchout::Engine::Result.new(pins: pins, requires: [], private_calls: [])
      source = Branchout::Emitters.render("rspec", result, target, File.join(ROOT, "spec/bar_spec.rb"))
      parsed = Prism.parse(source)
      assert parsed.success?, source
      groups = []
      examples = 0
      walk = lambda do |node, group|
        if node.is_a?(Prism::CallNode) && node.name == :it
          group << node.arguments.arguments.first.unescaped
          examples += 1
        elsif node.is_a?(Prism::CallNode) && %i[describe context].include?(node.name) && node.block
          group << node.arguments.arguments.first.unescaped if node.name == :context
          groups << (inner = [])
          return walk.(node.block, inner)
        end
        node.compact_child_nodes.each { |child| walk.(child, group) }
      end
      walk.(parsed.value, [])
      assert_equal pins.length, examples, source
      groups.each { |texts| assert_equal texts.uniq, texts, source }
      groups.flatten.each { |text| assert_operator text.length, :<=, 80, text }
      groups.flatten.each { |text| refute_match(/(?:when |, | and )\[\d+\](?:\.| is )/, text) }
      groups.flatten.each { |text| refute_match(/(?:when |returns |, | and )\[(?:"[^"]*"|:\S+|\d+)\](?:\[|\.| is | => |: )/, text) }
    end
  end

  # A deep document whose texts are too long for 80 characters still names
  # each fact and each outcome from the argument or the Hash that holds it,
  # never from a bare bracket, and still tells its examples apart.
  def test_a_deep_document_names_its_leaves_from_what_holds_them
    keys = sampled_from(%w[report summary last_run result status head tests])
    target = Struct.new(:singleton, :const_name, :method_name, :entry, :display_path, :path, :parameters, :positional)
                   .new(true, "Assessor", :apply, "Assessor.apply", "lib/x.rb", File.join(ROOT, "lib/x.rb"), [], [Struct.new(:name).new(:doc)])
    Hegel.test do |tc|
      chain = lambda do
        path = tc.draw(arrays(keys, min_size: 2, max_size: 6))
        leaf = tc.draw(sampled_from(["failed", "timed out after 30 seconds", "passed in a long while", 0]))
        path.reverse.reduce(leaf) { |inner, key| tc.draw(booleans) ? { key => inner } : [{ key => inner }] }
      end
      pins = tc.draw(arrays(just(nil), min_size: 1, max_size: 4)).map do
        Branchout::Engine::Pin.new(input: Branchout::Input.new(args: [chain.()]), value: { "doc" => chain.() }, error: nil, covers: [])
      end
      pins = pins.uniq { |pin| pin.input.canonical }
      result = Branchout::Engine::Result.new(pins: pins, requires: [], private_calls: [])
      source = Branchout::Emitters.render("rspec", result, target, File.join(ROOT, "spec/x_spec.rb"))
      assert Prism.parse(source).success?, source
      texts = source.scan(/^ *(?:it|context) (.*) do$/).flatten.map { |literal| Prism.parse(literal).value.statements.body.first.unescaped }
      texts.each do |text|
        assert_operator text.length, :<=, 80, text
        refute_match(/(?:when |returns |, | and )\[(?:"[^"]*"|\d+)\]/, text)
      end
    end
  end

  # A path names each leaf as Ruby reaches it, a Symbol key bare and a
  # String key quoted, so params["sku"] never reads as if a lookup by the
  # Symbol :sku would find it. A bare .name reads as [:name].
  def test_a_path_reaches_its_leaf_with_the_key_its_hash_holds
    key = one_of(text(max_size: 3), text(max_size: 3).map(&:to_sym))
    Hegel.test do |tc|
      value = tc.draw(recursive(one_of(integers(min_value: 0, max_value: 9), just(nil)), max_leaves: 8) do |inner|
        one_of(arrays(inner, min_size: 1, max_size: 3), hashes(key, inner, min_size: 1, max_size: 3))
      end)
      leaves = []
      Branchout::Emitters::Support.collect_leaves(value, [], leaves)
      leaves.each do |path, leaf|
        text = Branchout::Emitters::Support.path_text(path, "root").gsub(/\.([A-Za-z_][A-Za-z0-9_]*[?!]?)/, '[:\1]')
        assert_equal [leaf], [eval(text, binding.tap { |scope| scope.local_variable_set(:root, value) })], text # rubocop:disable Security/Eval
      end
    end
  end

  # Ruby source that is a plain literal names as the value it builds.
  def test_a_plain_literal_names_as_its_value
    Hegel.test do |tc|
      value = Branchout::Input.new(args: [tc.draw(json_values)]).args.first
      value = value.transform_keys(&:to_sym) if value.is_a?(Hash) && tc.draw(booleans)
      code = Branchout::Code.parse(Branchout::Emitters::Support.ruby_literal(value))
      assert_equal [value], [Branchout::Emitters::Support.written_value(code)]
    end
  end

  # An input that passes a String-keyed Hash and one that passes the same
  # Hash with Symbol keys, as Ruby source, pin the same value under two
  # unique names that are method names.
  def test_string_and_symbol_keyed_siblings_get_unique_names
    key = text(min_size: 1, max_size: 3)
    Hegel.test do |tc|
      value = tc.draw(hashes(key, one_of(integers(min_value: 0, max_value: 9), arrays(hashes(key, integers(min_value: 0, max_value: 9), max_size: 2), max_size: 2)),
                             min_size: 1, max_size: 3))
      symbolized = ->(item) { item.is_a?(Hash) ? item.to_h { |k, v| [k.to_sym, symbolized.(v)] } : item.is_a?(Array) ? item.map(&symbolized) : item }
      code = { "ruby" => Branchout::Emitters::Support.ruby_literal(symbolized.(value)) }
      pins = [[value], [code]].map { |args| Branchout::Engine::Pin.new(input: Branchout::Input.new(args: args), value: 1, error: nil, covers: []) }
      names = Branchout::Emitters::Support.test_names(pins)
      assert_equal names.uniq, names
      assert(names.all? { |name| name.match?(/\Atest_[a-z0-9_]+\z/) && !name.include?("__") && name.length <= 104 }, names.inspect)
    end
  end

  # Two leaves whose Hash keys differ get different names, however one
  # ends the other: id and items[0].id are never both "id".
  def test_leaves_with_different_keys_get_different_key_names
    Hegel.test do |tc|
      step = one_of(sampled_from(%w[id items status result]), integers(min_value: 0, max_value: 1))
      paths = tc.draw(arrays(arrays(step, min_size: 1, max_size: 4), min_size: 2, max_size: 5)).uniq
      named = paths.reject { |path| path.grep(String).empty? }.uniq { |path| path.grep(String) }
      names = named.map { |path| Branchout::Emitters::Support.telling_key(path, paths).text }
      assert_equal names.uniq, names
    end
  end

  # A number's word fits a name and keeps the fact: its sign, its leading
  # digits, and how many digits it has.
  def test_a_number_word_keeps_its_sign_leading_digits_and_size
    Hegel.test do |tc|
      value = tc.draw(integers(min_value: -10**60, max_value: 10**60))
      word = Branchout::Emitters::Support.number_word(value)
      digits = value.abs.to_s
      assert_operator word.length, :<=, [digits.length, 9].max + 3
      assert_equal value.negative?, word.start_with?("neg")
      body = word.delete_prefix("neg")
      assert digits.start_with?(body[/\A\d+/])
      assert_equal digits.length, body.include?("e") ? 3 + body.split("e").last.to_i : body.length
    end
  end

  def test_an_emitted_class_name_is_a_constant
    Hegel.test do |tc|
      method_name = tc.draw(from_regex("[a-z_][a-z0-9_]{0,12}[?!=]?", fullmatch: true))
      target = Struct.new(:const_name, :method_name).new("Foo::Bar", method_name.to_sym)
      assert_match(/\AFooBar[A-Za-z0-9]*CharacterizationTest\z/, Branchout::Emitters::Support.class_name_for(target))
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

  # test/generated requires examples/hidden_bug.rb before explore sets up
  # coverage, so explore measures a copy that loads after it.
  def test_the_report_does_not_depend_on_input_order_or_repeats
    dir = Dir.mktmpdir
    target = File.join(dir, "hidden_bug.rb")
    FileUtils.cp(File.join(ROOT, "examples/hidden_bug.rb"), target)
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
  ensure
    FileUtils.rm_rf(dir)
  end
end
