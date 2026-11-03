# frozen_string_literal: true

require "coverage"

module Branchout
  module CoverageSession
    module_function

    def install
      return unless Coverage.state == :idle

      previous = $VERBOSE
      $VERBOSE = nil
      Coverage.setup(lines: true, branches: true)
    ensure
      $VERBOSE = previous if defined?(previous)
    end
  end

  # Loads the target under Coverage and runs one input at a time.
  # Branch counters are cleared between calls. Load-time execution is discarded.
  class Runner
    Execution = Struct.new(:input, :value, :error, :lines, :branches, :path_ids, :origin, keyword_init: true)
    # +name+ is the missing name of a NameError, which is stable where its
    # message is not: Ruby 3.4 reworded both NameError and NoMethodError.
    ExceptionInfo = Struct.new(:class_name, :message, :loc, :stable_message, :name, keyword_init: true)

    attr_reader :template

    # +requires+ are files the target needs loaded first, such as its
    # library's entry file. They load after coverage starts, so the target
    # is measured even when one of them requires it.
    def initialize(target, timeout:, requires: [])
      @target = target
      @timeout = timeout
      @requires = requires
      boot
    end

    def execute(input)
      check_receiver(input)
      value = nil
      error = nil
      measure do
        value = invoke(input)
      rescue Exception => e # rubocop:disable Lint/RescueException
        error = ExceptionInfo.from(
          e,
          @target.display_path,
          @target.path,
          fallback_line: @target.ranges.first&.begin
        )
      end
      data = extract(Coverage.result(stop: false, clear: true))
      Execution.new(input: input, value: value, error: error, lines: data[:lines], branches: data[:branches])
    end

    private

    def boot
      CoverageSession.install
      begin
        measure do
          @requires.each { |path| require path }
          require @target.path
        end
      rescue LoadError, SyntaxError => e
        raise Error, "failed to load #{@target.display_path}: #{e.message}"
      end
      Coverage.result(stop: false, clear: true)
      resolve
      Coverage.result(stop: false, clear: true)
      @template = extract(Coverage.result(stop: false, clear: false))
    end

    def resolve
      const = @target.const_name.split("::").inject(Object) do |mod, name|
        mod.const_get(name)
      end
      if @target.singleton
        @method = const.method(@target.method_name)
      else
        unless const.is_a?(Class)
          raise Error, "#{@target.const_name} is a module, so its methods have no receiver; " \
                       "target #{@target.const_name}.#{@target.method_name}"
        end

        @const = const
        @method = const.instance_method(@target.method_name)
        @required_new_arguments = const.instance_method(:initialize).parameters.count { |kind, _name| kind == :req }
      end
    rescue NameError => e
      raise Error, "cannot resolve #{@target.entry}: #{e.message}"
    end

    def check_receiver(input)
      if @target.singleton
        raise Error, "#{@target.entry} is not an instance method, so its inputs take no \"new\"" if input.receiver
      elsif input.receiver.nil? && @required_new_arguments.positive?
        raise Error, "#{@target.const_name}#initialize requires #{@required_new_arguments} arguments; " \
                     "give them in \"new\" on each input and pass --strategy inputs"
      end
    end

    def invoke(input)
      previous_out = $stdout
      previous_err = $stderr
      $stdout = StringIO.new
      $stderr = StringIO.new
      args, kwargs = fresh_arguments(input)
      run = proc do
        if @target.singleton
          @method.call(*args, **kwargs)
        else
          # Each call gets a new receiver, as an emitted test does, so one
          # input cannot change the state the next input sees.
          new_args, new_kwargs = input.receiver ? fresh_arguments(input.receiver) : [[], {}]
          @method.bind_call(@const.new(*new_args, **new_kwargs), *args, **kwargs)
        end
      end
      if @timeout
        Timeout.timeout(@timeout, &run)
      else
        run.call
      end
    ensure
      $stdout = previous_out if defined?(previous_out) && previous_out
      $stderr = previous_err if defined?(previous_err) && previous_err
    end

    # Each call gets its own mutable copy, as a literal in an emitted test
    # does, so the target cannot raise FrozenError or rewrite the input.
    def fresh_arguments(input)
      [Marshal.load(Marshal.dump(input.args)), Marshal.load(Marshal.dump(input.kwargs)).transform_keys(&:to_sym)]
    end

    def measure
      Coverage.resume
      yield
    ensure
      Coverage.suspend if Coverage.state == :running
    end

    def extract(raw)
      data = file_data(raw)
      lines = data && data[:lines] ? data[:lines].dup : []
      branches = {}
      raw_branches = data && data[:branches] ? data[:branches] : {}
      raw_branches.each do |branch_key, arms|
        next unless @target.covers_line?(branch_key[2])

        branches[branch_key.dup] = arms.each_with_object({}) { |(arm_key, count), out|
          out[arm_key.dup] = count
        }
      end
      {lines: lines, branches: branches}
    end

    def file_data(raw)
      wanted = File.expand_path(@target.path)
      raw.each do |key, value|
        next unless value.is_a?(Hash)

        candidate = File.expand_path(key)
        return value if candidate == wanted
      end
      nil
    end
  end

  class Runner::ExceptionInfo
    def self.from(exception, display_path, real_path, fallback_line: nil)
      raw = exception.message.to_s
      clean = raw.gsub(/#<[^>]*>/, "#<obj>").gsub(/0x[0-9a-f]+/i, "0xID").gsub(/\s+/, " ").strip
      clean = clean[0, 180]
      stable = raw.gsub(/\s+/, " ").strip == clean
      loc = locate(exception, display_path, real_path)
      if loc.nil? && fallback_line && exception.is_a?(Timeout::Error)
        loc = "#{display_path}:#{fallback_line}"
      end
      name = exception.is_a?(Timeout::Error) ? "Timeout::Error" : exception.class.name
      missing = exception.name if exception.is_a?(NameError) && exception.name.is_a?(Symbol)
      new(class_name: name, message: clean, loc: loc, stable_message: stable, name: missing)
    end

    def self.locate(exception, display_path, real_path)
      Array(exception.backtrace).each do |frame|
        next unless frame =~ /\A(.+):(\d+):/

        file = Regexp.last_match(1)
        line = Regexp.last_match(2).to_i
        candidate = File.expand_path(file)
        return "#{display_path}:#{line}" if candidate == File.expand_path(real_path)
      end
      nil
    end
  end
end
