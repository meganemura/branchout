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

    # +private_calls+ names the entry and new when they are private or
    # protected, so a test has to call them through send.
    attr_reader :template, :private_calls

    # +requires+ are files the target needs loaded first, such as its
    # library's entry file. They load after coverage starts, so the target
    # is measured even when one of them requires it. Each one's directory
    # joins the load path.
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
      begin
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
      load_file = loader_refusing_another_branchout
      # A file of the running branchout, such as its own lib, loaded before
      # coverage started, so it is loaded again to be measured.
      preloaded = $LOADED_FEATURES.include?(File.realpath(@target.path))
      begin
        quietly do
          measure do
            @requires.each do |path|
              $LOAD_PATH.unshift(File.dirname(path)) unless $LOAD_PATH.include?(File.dirname(path))
              load_file.(path)
            end
            preloaded ? load(@target.path) : load_file.(@target.path)
          end
        end
      rescue LoadError, SyntaxError => e
        raise Error, "failed to load #{@target.display_path}: #{e.message}"
      rescue NameError => e
        hint = " Pass the file that defines #{e.name} with --require." unless e.is_a?(NoMethodError)
        raise Error, "failed to load #{@target.display_path}: #{e.message.lines.first.strip} (#{e.class}).#{hint}"
      end
      Coverage.result(stop: false, clear: true)
      resolve
      Coverage.result(stop: false, clear: true)
      @template = extract(Coverage.result(stop: false, clear: false))
    end

    # Another checkout's lib/branchout reopens the running tool's classes,
    # so the run would mix two versions. The check is a closure built before
    # anything loads, because the copy can redefine every method and constant.
    def loader_refusing_another_branchout
      lib = File.expand_path("..", __dir__)
      own = Dir[File.join(lib, "**/*.rb")].map { |file| file.delete_prefix(lib) }
      lambda do |path|
        loaded = $LOADED_FEATURES.length
        require path
        copy = $LOADED_FEATURES[loaded..].any? do |feature|
          !feature.start_with?("#{lib}/") && own.any? { |name| feature.end_with?(name) }
        end
        next unless copy

        raise Error, "#{Target.display_path(path)} loads another copy of branchout, which replaces the running one's classes. " \
                     "Run that copy's own bin/branchout instead."
      end
    end

    def resolve
      const = @target.const_name.split("::").inject(Object) do |mod, name|
        mod.const_get(name)
      end
      if @target.singleton
        @method = const.method(@target.method_name)
        @private_calls = const.singleton_class.public_method_defined?(@target.method_name) ? [] : [@target.method_name]
      else
        unless const.is_a?(Class)
          raise Error, "#{@target.const_name} is a module, so its methods have no receiver; " \
                       "target #{@target.const_name}.#{@target.method_name}"
        end

        @const = const
        @method = const.instance_method(@target.method_name)
        @required_new_arguments = const.instance_method(:initialize).parameters.count { |kind, _name| kind == :req }
        @private_calls = [[const.singleton_class, :new], [const, @target.method_name]]
                         .reject { |owner, name| owner.public_method_defined?(name) }.map(&:last)
      end
    rescue NameError => e
      raise Error, "cannot resolve #{@target.entry}: #{e.message}"
    end

    def check_receiver(input)
      if @target.singleton
        raise Error, "#{@target.entry} is not an instance method, so its inputs take no \"new\"" if input.receiver
        raise Error, "#{@target.entry} is not an instance method, so its inputs take no \"setup\"" unless input.setup.empty?
      elsif input.receiver.nil? && @required_new_arguments.positive?
        raise Error, "#{@target.const_name}#initialize requires #{@required_new_arguments} arguments; " \
                     "give them in \"new\" on each input. mutate and random fill \"new\" only when #{@target.display_path} defines initialize"
      end
    end

    # The target's own output is discarded, at load time too, so stdout
    # stays the report.
    def quietly
      previous_out = $stdout
      previous_err = $stderr
      $stdout = StringIO.new
      $stderr = StringIO.new
      yield
    ensure
      $stdout = previous_out
      $stderr = previous_err
    end

    def invoke(input)
      quietly { run_entry(input) }
    end

    def run_entry(input)
      args, kwargs = fresh_arguments(input)
      run = proc do
        if @target.singleton
          measure { @method.call(*args, **kwargs) }
        else
          receiver = prepared_receiver(input)
          measure { @method.bind_call(receiver, *args, **kwargs) }
        end
      end
      if @timeout
        Timeout.timeout(@timeout, &run)
      else
        run.call
      end
    end

    # Each input gets a new receiver, as an emitted test does, so one input
    # cannot change the state the next input sees. new and the setup calls
    # run outside coverage: the arms they take are not the entry's.
    def prepared_receiver(input)
      new_args, new_kwargs = input.receiver ? fresh_arguments(input.receiver) : [[], {}]
      receiver = @const.send(:new, *new_args, **new_kwargs)
      input.setup.each do |call|
        call_args, call_kwargs = fresh_arguments(call.arguments)
        receiver.public_send(call.method_name, *call_args, **call_kwargs)
      end
      receiver
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
