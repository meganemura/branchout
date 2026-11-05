# frozen_string_literal: true

require "rbconfig"
require_relative "coverage_session"

module Branchout
  # Loads the target under Coverage and runs one input at a time.
  # Branch counters are cleared between calls. Load-time execution is discarded.
  class Runner
    # +thawed+ is true when the input ran with unfrozen Strings, because
    # with frozen ones, as literals in an emitted test are, it raised
    # FrozenError.
    Execution = Struct.new(:input, :value, :error, :lines, :branches, :path_ids, :origin, :thawed, keyword_init: true)
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
    # joins the end of the load path, after the gems, because a Rails app's
    # config/environment.rb sits beside config/puma.rb. Each +load_paths+
    # directory (-I) goes first, as ruby -I puts it.
    # +host+ is the test that runs explore from inside a suite, which loaded
    # the target and the requires already.
    def initialize(target, timeout:, requires: [], load_paths: [], host: nil)
      @target = target
      @timeout = timeout
      @requires = requires
      @load_paths = load_paths
      @host = host
      @host ? attach : boot
    end

    # An input runs with frozen Strings, as an emitted test's literals are.
    # Only when that raises FrozenError and unfrozen Strings do not does
    # it keep the unfrozen run, which the emitted test then writes as +"".
    # In a suite, an around that did not run the input in ROLL_BACK, such as
    # RUN_ONLY, keeps what the first run wrote, which a second run would see
    # and no emitted test would, so there the FrozenError stays.
    def execute(input)
      check_receiver(input)
      frozen = attempt(input, false)
      return frozen unless frozen.error&.class_name == "FrozenError"
      return frozen if @host && !@rolled_back

      thawed = attempt(input, true)
      thawed.error&.class_name == "FrozenError" ? frozen : thawed
    end

    private

    def attempt(input, thawed)
      value, error = @host ? refusing_lets(input) { outcome(input, thawed) } : outcome(input, thawed)
      data = extract(Coverage.result(stop: false, clear: true))
      Execution.new(input: input, value: value, error: error, lines: data[:lines], branches: data[:branches], thawed: thawed)
    end

    def outcome(input, thawed)
      [invoke(input, thawed), nil]
    rescue Exception => e # rubocop:disable Lint/RescueException
      [nil, ExceptionInfo.from(e, @target.display_path, @target.path, fallback_line: @target.ranges.first&.begin)]
    end

    def refusing_lets(input, &call)
      read, made, result = @host.lets_read_by(&call)
      return result if read.empty?

      savepoint = " A let an input reads first is made in that input's rolled-back savepoint and kept for the next input." unless made.empty?
      raise Error, "the input #{Canon.json(input.to_h)} reads #{read.map { |name| "let(:#{name})" }.join(", ")} " \
                   "of the exploring test, which the emitted test does not have.#{savepoint} Build it in the input's Ruby."
    end

    def boot
      CoverageSession.install
      load_file = loader_refusing_another_branchout
      loaded_with_tool = target_loaded?
      loading = @target.path
      begin
        quietly do
          measure do
            @load_paths.reverse_each { |dir| $LOAD_PATH.unshift(dir) unless $LOAD_PATH.include?(dir) }
            @requires.each do |path|
              $LOAD_PATH.push(File.dirname(path)) unless $LOAD_PATH.include?(File.dirname(path))
              loading = path
              load_file.(path)
            end
            loading = @target.path
            loaded = target_loaded?
            @target_required = !loaded_with_tool && loaded
            # Loading the file again would define its classes a second
            # time, so an object built from the first ones is not one of them.
            load_file.(@target.path) unless loaded
          end
        end
      rescue Error
        raise
      rescue LoadError, SyntaxError => e
        raise Error, "failed to load #{Target.display_path(loading)}: #{e.message}"
      rescue NameError => e
        hint = " Pass the file that defines #{e.name} with --require." unless e.is_a?(NoMethodError)
        raise Error, "failed to load #{Target.display_path(loading)}: #{e.message.lines.first.strip} (#{e.class}).#{hint}"
      rescue StandardError => e
        raised = e.backtrace_locations&.first
        at = " at #{Target.display_path(raised.path)}:#{raised.lineno}" if raised
        raise Error, "failed to load #{Target.display_path(loading)}: #{e.message.lines.first&.strip} (#{e.class}#{at})"
      end
      unless target_measured?
        raise Error, "#{@target.display_path} loaded before explore set up coverage, so Coverage has no arms for it, " \
                     "and loading it again would define its classes a second time."
      end
      resolve
      @not_counted = callees_in_other_files(Coverage.result(stop: false, clear: true))
      @template = extract(Coverage.peek_result)
    end

    # Loading the target again would run its class body twice, and a
    # Rails model declares validations and callbacks there, so the target
    # is measured only when it loaded after branchout/coverage.
    def attach
      unless Coverage.state == :suspended
        raise Error, "Coverage is #{Coverage.state}, so explore cannot measure #{@target.display_path}. " \
                     "Require \"branchout/coverage\" first in the test file that explores, before its helper, " \
                     "and run without another coverage tool such as SimpleCov."
      end
      unless Coverage.peek_result[File.expand_path(@target.path)]&.key?(:branches)
        raise Error, "#{@target.display_path} loaded before branchout/coverage, so Coverage has no arms for it. " \
                     "Require \"branchout/coverage\" first in the test file that explores, before its helper, " \
                     "and run that file alone."
      end
      @target_required = true
      resolve
      @not_counted = callees_in_other_files(Coverage.result(stop: false, clear: true))
      @template = extract(Coverage.peek_result)
    end

    # Kernel#load, as Rails uses for an initializer, leaves the file out of
    # $LOADED_FEATURES, but coverage holds every file loaded after setup.
    def target_loaded?
      $LOADED_FEATURES.include?(File.realpath(@target.path)) || target_measured?
    end

    def target_measured?
      wanted = File.expand_path(@target.path)
      Coverage.peek_result.any? { |file, _data| File.expand_path(file) == wanted }
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
        # Each name is one its lexical parent defines, so a name that
        # Module#constants leaves out is a private constant.
        hidden = !mod.constants.include?(name.to_sym)
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
        next if installed_dirs.any? { |dir| file.start_with?(dir) }

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

    # Where installed gems and Ruby's own library live. An app cannot move
    # a check into one, so its methods hide none of the app's arms.
    def installed_dirs
      @installed_dirs ||= [*(Gem.path if defined?(Gem)), RbConfig::CONFIG["rubylibdir"]].map { |dir| File.join(File.expand_path(dir), "") }
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
        raise Error, "#{@target.entry} is not an instance method, so its inputs take no \"new\" or \"receiver\"" if input.receiver
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

    def invoke(input, thawed)
      return quietly { run_entry(input, thawed) } unless @host

      value = nil
      Thread.current[:branchout_rolled_back] = false
      begin
        quietly { @host.around.call { value = run_entry(input, thawed) } }
      ensure
        @rolled_back = Thread.current[:branchout_rolled_back]
      end
      value
    end

    def run_entry(input, thawed)
      scope = new_scope
      run = proc do
        receiver = prepared_receiver(input, scope, thawed) unless @target.singleton
        args, kwargs = fresh_arguments(input, scope, thawed)
        block = scope.eval("proc #{input.block.source}", "(input)") if input.block
        if @target.singleton
          measure { @method.call(*args, **kwargs, &block) }
        else
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
    # A receiver the input's Ruby builds gets the name the emitted test
    # gives it, so the arguments can be read from it, as in
    # "room.participants.first".
    def prepared_receiver(input, scope, thawed)
      if input.receiver.is_a?(Code)
        receiver = scope.eval(input.receiver.source, "(input)")
        scope.local_variable_set(Emitters::Support.built_receiver_name(@target), receiver)
      else
        new_args, new_kwargs = input.receiver ? fresh_arguments(input.receiver, scope, thawed) : [[], {}]
        receiver = @const.send(:new, *new_args, **new_kwargs)
      end
      input.setup.each do |call|
        call_args, call_kwargs = fresh_arguments(call.arguments, scope, thawed)
        receiver.public_send(call.method_name, *call_args, **call_kwargs)
      end
      receiver
    end

    # Each call gets its own copy, so the target cannot rewrite the input.
    # Its Strings are frozen, as literals in an emitted test are, unless
    # +thawed+. Code is evaluated here, as an emitted test does, so each
    # call gets its own object.
    def fresh_arguments(input, scope, thawed)
      [built(Marshal.load(Marshal.dump(input.args)), scope, thawed),
       built(Marshal.load(Marshal.dump(input.kwargs)), scope, thawed).transform_keys(&:to_sym)]
    end

    def built(value, scope, thawed)
      case value
      when Code then scope.eval(value.source, "(input)")
      when String then thawed ? value : value.freeze
      when Array then value.map! { |item| built(item, scope, thawed) }
      when Hash then value.transform_values! { |item| built(item, scope, thawed) }
      else value
      end
    end

    # Where one input's Ruby runs: the top level, as in an emitted test, or
    # in a suite the test itself, so it reaches the test's factories,
    # fixtures, and helpers. A string eval keeps this method's locals out.
    def new_scope
      @host ? @host.test.instance_eval("binding", __FILE__, __LINE__) : TOPLEVEL_BINDING.eval("binding", __FILE__, __LINE__)
    end

    def measure
      Coverage.resume
      yield
    ensure
      Coverage.suspend if Coverage.state == :running
    end

    # The target loaded under CoverageSession, which measures lines and
    # branches, so the result holds both for its file.
    def extract(raw)
      wanted = File.expand_path(@target.path)
      _file, data = raw.find { |file, _data| File.expand_path(file) == wanted }
      branches = data[:branches].select { |branch_key, _arms| @target.covers_line?(branch_key[2]) }
      {lines: data[:lines].dup, branches: branches.to_h { |branch_key, arms| [branch_key.dup, arms.transform_keys(&:dup)] }}
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
      missing = exception.name if exception.is_a?(NameError) && exception.name.is_a?(Symbol)
      new(class_name: exception.class.name, message: clean, loc: loc, stable_message: stable, name: missing, exact_message: (raw if stable),
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
