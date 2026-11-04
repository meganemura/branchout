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
    # +message+ has its whitespace folded for reports; a test pins
    # +exact_message+, the message as raised, when that is stable.
    # +message_pattern+ is the source of a Regexp for a message that quotes
    # a backtrace frame: Ruby 3.4 labels a frame 'Box.run' where 3.3 wrote
    # `run', so the pattern keeps the rest and accepts either label.
    ExceptionInfo = Struct.new(:class_name, :message, :loc, :stable_message, :name, :exact_message, :message_pattern,
                               keyword_init: true)
    # +arms+ is nil when the callee's file holds no coverage to count from.
    Callee = Struct.new(:name, :loc, :arms, keyword_init: true)

    # +private_calls+ names the entry and new when they are private or
    # protected, so a test has to call them through send.
    # +const_expression+ names the target class as a test can write it:
    # a private constant has to be reached through const_get.
    # +target_required+ is true when a --require file already loads the
    # target, so a test needs no require of its own for it.
    # +not_counted+ lists the methods in other files that the counted code
    # calls on self, such as a parent class's helper. Their arms are not in
    # the report, so a check moved into one makes arms_total smaller.
    attr_reader :template, :private_calls, :target_required, :const_expression, :not_counted

    # +requires+ are files the target needs loaded first, such as its
    # library's entry file. They load after coverage starts, so the target
    # is measured even when one of them requires it. Each one's directory
    # joins the load path, as each +load_paths+ directory (-I) does.
    def initialize(target, timeout:, requires: [], load_paths: [])
      @target = target
      @timeout = timeout
      @requires = requires
      @load_paths = load_paths
      boot
    end

    def execute(input)
      check_receiver(input)
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
            @load_paths.reverse_each { |dir| $LOAD_PATH.unshift(dir) unless $LOAD_PATH.include?(dir) }
            @requires.each do |path|
              $LOAD_PATH.unshift(File.dirname(path)) unless $LOAD_PATH.include?(File.dirname(path))
              load_file.(path)
            end
            @target_required = !preloaded && $LOADED_FEATURES.include?(File.realpath(@target.path))
            preloaded ? load(@target.path) : load_file.(@target.path)
          end
        end
      rescue LoadError, SyntaxError => e
        raise Error, "failed to load #{@target.display_path}: #{e.message}"
      rescue NameError => e
        hint = " Pass the file that defines #{e.name} with --require." unless e.is_a?(NoMethodError)
        raise Error, "failed to load #{@target.display_path}: #{e.message.lines.first.strip} (#{e.class}).#{hint}"
      end
      resolve
      @not_counted = callees_in_other_files(Coverage.result(stop: false, clear: true))
      @template = extract(Coverage.result(stop: false, clear: false))
    end

    # Another checkout's lib/branchout reopens the running tool's classes,
    # so the run would mix two versions. A copy is a file that opens the
    # Branchout namespace; a project file that only shares a file name with
    # one of branchout's is not. The running lib is loaded already, so
    # require never opens its classes again. The check is a closure built
    # before anything loads, because the copy can redefine every method and
    # constant.
    def loader_refusing_another_branchout
      lambda do |path|
        copy = false
        opened = TracePoint.new(:class) do |event|
          name = Module.instance_method(:name).bind_call(event.self).to_s
          copy ||= name == "Branchout" || name.start_with?("Branchout::")
        end
        opened.enable { require path }
        next unless copy

        raise Error, "#{Target.display_path(path)} loads another copy of branchout, which replaces the running one's classes. " \
                     "Run that copy's own bin/branchout instead."
      end
    end

    def resolve
      expression = nil
      const = @target.const_name.split("::").inject(Object) do |mod, name|
        hidden = mod.const_defined?(name, false) && !mod.constants(false).include?(name.to_sym)
        expression = if hidden
                       "#{expression || "Object"}.const_get(:#{name})"
                     else
                       [expression, name].compact.join("::")
                     end
        mod.const_get(name)
      end
      @const_expression = expression
      @owner = const
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
        @required_new = required_text(const.instance_method(:initialize).parameters)
        @private_calls = [[const.singleton_class, :new], [const, @target.method_name]]
                         .reject { |owner, name| owner.public_method_defined?(name) }.map(&:last)
      end
    rescue NameError => e
      raise Error, "cannot resolve #{@target.entry}: #{e.message}"
    end

    # +loaded+ is the coverage of everything loaded, which holds the arms of
    # each file loaded after coverage started. A method defined in C, in
    # Ruby's own prelude, or by a file loaded before that has no arms to
    # count here.
    def callees_in_other_files(loaded)
      # CoverageSession measures lines and branches, so every file's data
      # is a Hash that holds both.
      branches = loaded.to_h { |file, data| [File.expand_path(file), data[:branches]] }
      on_self = @target.outside_calls.map do |singleton, name|
        -> { [singleton, @owner, singleton ? @owner.method(name) : @owner.instance_method(name)] }
      end
      on_built = @target.typed_calls.map do |namespace, const, name|
        -> { built_class(namespace, const).then { |built| [false, built, built.instance_method(name)] } }
      end
      found = (on_self + on_built).filter_map do |lookup|
        singleton, holder, method = lookup.call
        # An attribute reader or writer has no instructions, so no arms.
        next if RubyVM::InstructionSequence.of(method).nil?

        # require, require_relative, and the runner load files by absolute
        # path, so the location is already absolute, as coverage keys are.
        file, line = method.source_location
        next if file.start_with?("<internal:")
        next if file == File.expand_path(@target.path)

        lines = Target.def_lines(file, line)
        arms = lines && branches[file]&.sum { |branch_key, arms_of| lines.cover?(branch_key[2]) ? arms_of.length : 0 }
        # A method with no arms hides none.
        next if arms&.zero?

        [file, line, Callee.new(name: callee_name(method.owner, holder, singleton, method.name), loc: "#{Target.display_path(file)}:#{line}", arms: arms)]
      rescue NameError
        nil
      end
      found.uniq { |file, line, _callee| [file, line] }.sort_by { |file, line, _callee| [file, line] }.map(&:last)
    end

    # The class +const+ names where it is written, inside +namespace+, as
    # Ruby's lexical lookup finds it.
    def built_class(namespace, const)
      scopes = namespace.split("::")
      scopes.length.downto(0).each do |depth|
        name = [*scopes.first(depth), const].join("::")
        return Object.const_get(name) if Object.const_defined?(name)
      end
      Object.const_get(const)
    end

    # +holder+ is the class the call is made on. A module with no name has
    # only an inspect that carries its address, so it is named by +holder+.
    def callee_name(owner, holder, singleton, name)
      return "#{owner.attached_object.name}.#{name}" if owner.singleton_class?

      "#{owner.name || "#{holder.name} (an anonymous module)"}#{singleton ? "." : "#"}#{name}"
    end

    # What an input has to give in "new": the required positional
    # arguments and the required keywords of initialize, with their count,
    # or nil when it needs neither.
    def required_text(parameters)
      count = parameters.count { |kind, _name| kind == :req }
      keywords = parameters.filter_map { |kind, name| "#{name}:" if kind == :keyreq }
      parts = []
      parts << "#{count} argument#{"s" unless count == 1}" if count.positive?
      parts << "the keyword#{"s" if keywords.size > 1} #{keywords.join(", ")}" unless keywords.empty?
      [parts.join(" and "), count + keywords.size] unless parts.empty?
    end

    def check_receiver(input)
      if @target.singleton
        raise Error, "#{@target.entry} is not an instance method, so its inputs take no \"new\"" if input.receiver
        raise Error, "#{@target.entry} is not an instance method, so its inputs take no \"setup\"" unless input.setup.empty?
      elsif input.receiver.nil? && @required_new
        text, count = @required_new
        private_new = " #{@target.const_name}.new is private, so explore and the emitted tests call it through send." if @private_calls.include?(:new)
        raise Error, "#{@target.const_name}#initialize requires #{text}; " \
                     "give #{count == 1 ? "it" : "them"} in \"new\" on each input.#{private_new} " \
                     "mutate and random fill \"new\" only when #{@target.display_path} defines initialize"
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
      block = evaluate("proc #{input.block.source}") if input.block
      run = proc do
        if @target.singleton
          measure { @method.call(*args, **kwargs, &block) }
        else
          receiver = prepared_receiver(input)
          measure { @method.bind_call(receiver, *args, **kwargs, &block) }
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
    # Code is evaluated here, at the top level as an emitted test does, so
    # each call gets its own object.
    def fresh_arguments(input)
      [built(Marshal.load(Marshal.dump(input.args))), built(Marshal.load(Marshal.dump(input.kwargs))).transform_keys(&:to_sym)]
    end

    def built(value)
      case value
      when Code then evaluate(value.source)
      when Array then value.map! { |item| built(item) }
      when Hash then value.transform_values! { |item| built(item) }
      else value
      end
    end

    def evaluate(source)
      TOPLEVEL_BINDING.eval(source, "(input)")
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
      pattern = frame_pattern(raw)
      whole = raw.gsub(/\s+/, " ").strip == clean
      stable = pattern.nil? && whole
      loc = locate(exception, display_path, real_path)
      if loc.nil? && fallback_line && exception.is_a?(Timeout::Error)
        loc = "#{display_path}:#{fallback_line}"
      end
      name = exception.is_a?(Timeout::Error) ? "Timeout::Error" : exception.class.name
      missing = exception.name if exception.is_a?(NameError) && exception.name.is_a?(Symbol)
      new(class_name: name, message: clean, loc: loc, stable_message: stable, name: missing, exact_message: (raw if stable),
          message_pattern: (pattern if whole))
    end

    FRAME_LABEL = /(:\d+:in )[`'][^`'\n]*'/

    def self.frame_pattern(raw)
      return nil unless FRAME_LABEL.match?(raw)

      parts = raw.split(FRAME_LABEL, -1)
      source = parts.each_with_index.map { |part, index| index.odd? ? "#{Regexp.escape(part)}[`'][^`'\\n]*'" : Regexp.escape(part) }
      "\\A#{source.join.gsub("\\ ", " ")}\\z"
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
