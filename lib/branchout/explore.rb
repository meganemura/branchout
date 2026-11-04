# frozen_string_literal: true

module Branchout
  # The test that runs explore from inside a suite. +test+ is the example or
  # test instance whose helpers, factories, and fixtures the inputs' Ruby
  # reaches. +around+ runs one input and undoes what it wrote. +test_class+
  # is the class an emitted minitest file inherits from, and +spec_type+ the
  # type metadata an emitted RSpec file gives its describe.
  Host = Data.define(:test, :around, :test_class, :spec_type) do
    # Runs the block with the test's lets forgotten, then puts them back.
    # Returns the names of the lets the block read, the names among them
    # that the test had not made before, and the block's result.
    # RSpec keeps a let's value in @__memoized, minitest/spec in @_memoized.
    def lets_read_by
      holder, name = let_values
      return [[], [], yield] unless holder

      kept = holder.instance_variable_get(name)
      holder.instance_variable_set(name, {})
      result = yield
      read = holder.instance_variable_get(name).keys
      [read, read.reject { |let| kept&.key?(let) }, result]
    ensure
      holder&.instance_variable_set(name, kept)
    end

    private

    def let_values
      rspec = test.instance_variable_get(:@__memoized) if test.instance_variable_defined?(:@__memoized)
      return [rspec, :@memoized] if rspec&.instance_variable_defined?(:@memoized)

      [test, :@_memoized] if defined?(Minitest::Spec) && test.is_a?(Minitest::Spec)
    end
  end

  # The helper files a suite loads before its tests, most specific first.
  # An emitted test requires the first one loaded from the working directory.
  HELPERS = %w[rails_helper.rb test_helper.rb spec_helper.rb].freeze

  # Each input runs in a savepoint that is rolled back, so no input sees the
  # rows another wrote, and the example's own rows are left as they were.
  # It marks the input as rolled back, also when an around calls it, so the
  # Runner knows that a second run of the input starts from the same rows.
  ROLL_BACK = lambda do |&input|
    ActiveRecord::Base.transaction(requires_new: true) do
      Thread.current[:branchout_rolled_back] = true
      input.call
      raise ActiveRecord::Rollback
    end
  end

  RUN_ONLY = ->(&input) { input.call }

  module_function

  # Explores +entry+ ("Loan#approve" or "Room.open!") from inside a test, and
  # returns the report the CLI prints. +within+ is the running test: pass
  # self. +inputs+ is the inputs file's list, or its path. The target is the
  # file that defines the entry, unless +target+ names it.
  def explore(entry, within:, inputs:, target: nil, emit_tests: nil, format: nil, json: false, pin_keys: [],
              requires: nil, around: nil, strategies: %w[inputs], seed: 0, random: 16, mutate_cap: 256, timeout: 1)
    target ||= defining_file(entry)
    user_inputs, type_overrides = inputs.is_a?(String) ? InputFile.load(inputs) : [parse_inputs(inputs), nil]
    requires ||= [loaded_helper].compact
    format = Emitters.resolve(format&.to_s, emit_tests) if emit_tests
    if emit_tests && requires.empty?
      raise Error, "the suite loaded no #{HELPERS.join(", ")} from #{Dir.pwd}, so an emitted test would not load the app; " \
                   "pass the helper file as requires:"
    end
    host = Host.new(test: within, around: around || (defined?(ActiveRecord::Base) ? ROLL_BACK : RUN_ONLY),
                    test_class: within.class.superclass.name, spec_type: spec_type_of(within))
    result = Engine.explore(
      target: target, entry: entry, user_inputs: user_inputs, type_overrides: type_overrides, seed: seed,
      strategies: strategies, random: random, mutate_cap: mutate_cap, timeout: timeout, requires: requires, host: host
    )
    if emit_tests
      warnings = Emitters.write(format, result, Target.parse(target, entry, type_overrides: type_overrides),
                                emit_tests, require_by_name: true, pin_keys: pin_keys)
      warnings.each { |line| $stderr.puts line }
    end
    json ? Report.json(result) : Report.text(result)
  end

  def defining_file(entry)
    match = /\A(.+?)([.#])([^.#]+)\z/.match(entry)
    raise Error, "entry #{entry.inspect} is not Const.method or Const#method" unless match

    const = Object.const_get(match[1])
    method = match[2] == "." ? const.method(match[3]) : const.instance_method(match[3])
    file, = method.source_location
    raise Error, "#{entry} has no Ruby source file; pass target:" unless file && File.file?(file)

    file
  rescue NameError => e
    raise Error, "cannot resolve #{entry}: #{e.message.lines.first.strip}"
  end

  # Symbol keys and JSON values come back as an inputs file would give them.
  def parse_inputs(inputs)
    raise Error, "inputs must be a list or an inputs file path" unless inputs.is_a?(Array)

    JSON.parse(JSON.generate(inputs)).each_with_index.map { |entry, index| InputFile.parse_entry(entry, "inputs[#{index}]") }
  end

  def loaded_helper
    root = "#{Dir.pwd}/"
    loaded = $LOADED_FEATURES.select { |path| path.start_with?(root) }
    HELPERS.each do |name|
      found = loaded.find { |path| File.basename(path) == name }
      return found if found
    end
    nil
  end

  def spec_type_of(test)
    test.class.metadata[:type] if test.class.respond_to?(:metadata)
  end

  private_class_method :spec_type_of, :defining_file, :parse_inputs, :loaded_helper
end
