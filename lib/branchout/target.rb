# frozen_string_literal: true

require "prism"

module Branchout
  # Static picture of one method: where it lives, which same-file callees it
  # reaches, the literals in that slice, and the condition text for each
  # decision Prism can see.
  class Target
    Parameter = Struct.new(:kind, :name, :default, :inferred_type, keyword_init: true)
    Literals = Struct.new(:ints, :floats, :strings, keyword_init: true)
    DefInfo = Struct.new(:const_name, :singleton, :node, keyword_init: true)

    STRING_METHODS = %i[
      include? start_with? end_with? split strip lstrip rstrip chomp
      match match? gsub sub scan upcase downcase chars to_i to_sym
      index rindex
    ].freeze
    ARRAY_METHODS = %i[each map select reject first last flatten flat_map].freeze
    HASH_METHODS = %i[keys values fetch each_pair key? value? merge].freeze
    NUMERIC_OPS = %i[+ - * / % == != < <= > >=].freeze

    ENTRY_RE = /\A([A-Z][A-Za-z0-9_]*(?:::[A-Z][A-Za-z0-9_]*)*)([.#])([A-Za-z_][A-Za-z0-9_]*[?!=]?)\z/

    attr_reader :path, :display_path, :source, :const_name, :method_name, :singleton,
                :parameters, :constructor, :ranges, :literals, :entry
    # [singleton, name] of each call on self that no method in this file
    # answers. Ruby's own lookup decides after load where each one lives.
    attr_reader :outside_calls
    # [namespace, class, name] of each call on an object the counted code
    # builds with Class.new, kept in a local or an instance variable.
    # +class+ is the constant as written, so Ruby resolves it in +namespace+.
    attr_reader :typed_calls

    def self.parse(path, entry, type_overrides: nil)
      new(path, entry, type_overrides: type_overrides).tap(&:parse)
    end

    def initialize(path, entry, type_overrides: nil)
      @path = File.expand_path(path)
      raise Error, "target file not found: #{path}" unless File.file?(@path)

      @display_path = self.class.display_path(@path)
      @source = File.read(@path)
      @entry = entry
      @type_overrides = type_overrides
      match = ENTRY_RE.match(entry.to_s)
      raise Error, "bad entry #{entry.inspect} (want Const.method or Const#method)" unless match

      @const_name = match[1]
      @singleton = match[2] == "."
      @method_name = match[3].to_sym
    end

    def parse
      result = Prism.parse(source)
      unless result.success?
        message = result.errors.map(&:message).join("; ")
        raise Error, "failed to parse #{display_path}: #{message}"
      end

      defs = []
      @superclasses = {}
      collect_defs(result.value, [], false, defs)
      index = {}
      defs.each do |info|
        key = [info.const_name, info.singleton, info.node.name]
        if index.key?(key)
          raise Error, "duplicate #{key[0]}#{key[1] ? "." : "#"}#{key[2]} in #{display_path}"
        end
        index[key] = info
      end

      lineage = lineage_of(const_name, defs)
      # The first definition along the superclass chain, as Ruby finds it
      # for the entry's own class.
      find = ->(in_singleton, name) { lineage.lazy.filter_map { |const| index[[const, in_singleton, name]] }.first }
      entry_def = find.(singleton, method_name)
      unless entry_def
        kind = singleton ? "." : "#"
        raise Error, "cannot find #{const_name}#{kind}#{method_name} in #{display_path}"
      end

      @ranges = []
      @outside_calls = []
      @typed_calls = []
      @literals = Literals.new(ints: [], floats: [], strings: [])
      @conditions = {}
      bodies = []
      seen = {}
      queue = [entry_def]
      until queue.empty?
        info = queue.shift
        next if seen[info]
        seen[info] = true

        loc = info.node.location
        @ranges << (loc.start_line..loc.end_line)
        body = info.node.body
        bodies << body if body
        index_conditions(body) if body
        built = info.singleton ? {} : built_ivars(defs, info.const_name)
        calls_on_built(body, built).each { |const, name| @typed_calls << [info.const_name, const, name] } if body
        bare_calls(body).each do |name|
          callee = find.(info.singleton, name)
          callee ? queue << callee : @outside_calls << [info.singleton, name]
        end
        next unless info.singleton

        calls_on_new(body).each do |name|
          [:initialize, name].each do |instance_name|
            callee = find.(false, instance_name)
            queue << callee if callee
          end
          @outside_calls << [false, name] unless find.(false, name)
        end
      end

      collect_literals(entry_def.node.parameters)
      bodies.each { |body| collect_literals(body) }
      @literals.ints = @literals.ints.uniq.sort
      @literals.floats = @literals.floats.uniq.sort
      @literals.strings = @literals.strings.uniq.sort
      @parameters = build_parameters(entry_def.node.parameters, bodies, @type_overrides)
      # The parameters of initialize, which an input's "new" fills for an
      # instance method. Empty when this file does not define initialize.
      init = singleton ? nil : index[[const_name, false, :initialize]]
      @constructor = init ? build_parameters(init.node.parameters, [init.node.body].compact, nil) : []
      self
    end

    def positional
      parameters.select { |param| param.kind == :req || param.kind == :opt }
    end

    def covers_line?(line)
      ranges.any? { |range| range.cover?(line) }
    end

    def condition_text(branch_type, bline, bcol, arm_type, aline, acol)
      node = @conditions[[bline, bcol]]
      text = condition_from(node, arm_type, aline, acol) if node
      text = squash(source_line(bline)) if text.nil? || text.empty?
      text.length > 160 ? "#{text[0, 157]}..." : text
    end

    def self.display_path(path)
      absolute = File.expand_path(path)
      root = "#{File.expand_path(Dir.pwd)}/"
      return absolute.delete_prefix(root) if absolute.start_with?(root)

      absolute
    end

    # The lines of the def that starts on +line+ of +path+, or nil when no
    # def starts there, as with define_method.
    def self.def_lines(path, line)
      stack = [Prism.parse(File.read(path)).value]
      until stack.empty?
        node = stack.pop
        loc = node.location
        return loc.start_line..loc.end_line if node.type == :def_node && loc.start_line == line

        stack.concat(node.compact_child_nodes)
      end
      nil
    rescue SystemCallError
      nil
    end

    private

    def build_parameters(params_node, bodies, type_overrides)
      list = []
      return list unless params_node

      params_node.requireds.each do |node|
        list << Parameter.new(kind: :req, name: node.name, default: nil, inferred_type: nil)
      end
      params_node.optionals.each do |node|
        list << Parameter.new(kind: :opt, name: node.name, default: literal_value(node.value), inferred_type: nil)
      end
      if params_node.rest
        list << Parameter.new(kind: :rest, name: params_node.rest.name, default: nil, inferred_type: "array")
      end
      params_node.keywords.each do |node|
        kind = node.type == :required_keyword_parameter_node ? :keyreq : :key
        default = node.respond_to?(:value) ? literal_value(node.value) : nil
        list << Parameter.new(kind: kind, name: node.name, default: default, inferred_type: nil)
      end

      evidence = Hash.new { |hash, key| hash[key] = Hash.new(0) }
      bodies.each { |body| walk_evidence(body, evidence) }
      positional_params = list.select { |param| param.kind == :req || param.kind == :opt }
      if type_overrides
        unless type_overrides.length == positional_params.length
          raise Error, "types length #{type_overrides.length} does not match #{positional_params.length} positional parameters"
        end
        positional_params.each_with_index { |param, index| param.inferred_type = type_overrides[index] }
      end

      list.each do |param|
        next if param.inferred_type

        param.inferred_type = choose_type(param, evidence[param.name])
      end
      list
    end

    # +const+ and its superclasses declared in this file, nearest first. A
    # superclass name resolves in the scope its class was written in.
    def lineage_of(const, defs)
      declared = defs.map(&:const_name) | @superclasses.keys
      chain = [const]
      while (parent = @superclasses[chain.last])
        scope, text = parent
        name = scope.length.downto(0).map { |depth| [*scope[0, depth], text].join("::") }.find { |candidate| declared.include?(candidate) }
        break if name.nil? || chain.include?(name)

        chain << name
      end
      chain
    end

    def module_segment(node, stack)
      full = node.respond_to?(:constant_path) ? node.constant_path&.slice : nil
      return full if stack.empty? && full && !full.empty?

      node.name.to_s
    end

    def choose_type(param, scores)
      no_evidence = scores.nil? || scores.values.all?(&:zero?)
      return type_from_default(param.default) if no_evidence && !param.default.nil?

      string = scores[:string]
      array = scores[:array]
      hash = scores[:hash]
      float = scores[:float]
      int = scores[:int]
      if [string, array, hash, float, int].all?(&:zero?)
        return type_from_default(param.default) || "int"
      end

      # String-specific calls beat numeric uses of the same name in a callee.
      return "string" if string.positive? && string >= array && string >= hash && string >= int && string >= float
      return "hash" if hash.positive? && hash >= array && hash >= int && hash >= float
      return "array" if array.positive? && array >= int && array >= float
      return "float" if float.positive? && float >= int

      "int"
    end

    def type_from_default(value)
      case value
      when Integer then "int"
      when Float then "float"
      when String then "string"
      when Array then "array"
      when Hash then "hash"
      when true, false then "bool"
      end
    end

    def condition_from(node, arm_type, aline, acol)
      case node.type
      when :if_node, :unless_node, :while_node, :until_node
        squash(node.predicate&.slice)
      when :case_node, :case_match_node
        if arm_type == :when || arm_type == :in
          found = node.conditions.find { |when_node| arm_matches?(when_node, aline, acol) }
          found ? squash(found.slice.lines.first) : nil
        else
          node.predicate ? "case #{squash(node.predicate.slice)} else" : "case else"
        end
      end
    end

    # Coverage places a when or in arm at its body, or at the keyword when
    # the body is empty.
    def arm_matches?(when_node, aline, acol)
      loc = when_node.statements&.location || when_node.location
      loc.start_line == aline && loc.start_column == acol
    end

    def index_conditions(node)
      return unless node.is_a?(Prism::Node)
      return if node.type == :def_node

      if condition_node?(node)
        loc = node.location
        @conditions[[loc.start_line, loc.start_column]] = node
      end
      node.compact_child_nodes.each { |child| index_conditions(child) }
    end

    def condition_node?(node)
      %i[if_node unless_node while_node until_node case_node case_match_node].include?(node.type)
    end

    def collect_literals(node)
      return unless node.is_a?(Prism::Node)
      return if node.type == :def_node

      case node.type
      when :integer_node
        @literals.ints << node.value if node.value.is_a?(Integer)
      when :float_node
        @literals.floats << node.value if node.value.is_a?(Float) && node.value.finite?
      when :string_node
        @literals.strings << node.unescaped if node.respond_to?(:unescaped) && node.unescaped.is_a?(String)
      end
      node.compact_child_nodes.each { |child| collect_literals(child) }
    end

    def bare_calls(node, acc = [])
      return acc unless node.is_a?(Prism::Node)
      return acc if node.type == :def_node

      if node.type == :call_node
        receiver = node.receiver
        acc << node.name if receiver.nil? || receiver.type == :self_node
      end
      node.compact_child_nodes.each { |child| bare_calls(child, acc) }
      acc
    end

    # Instance variables that a method of +const+ in this file sets to
    # Class.new, as initialize does for a collaborator: name => class text.
    def built_ivars(defs, const)
      defs.select { |info| info.const_name == const && !info.singleton && info.node.body }
          .flat_map { |info| assignments(info.node.body, :instance_variable_write_node) }.to_h
    end

    # [class text, method name] of each call on a value that this body
    # builds with Class.new: a local it assigns, an instance variable in
    # +ivars+, or the new call itself.
    def calls_on_built(body, ivars)
      locals = assignments(body, :local_variable_write_node).to_h
      found = []
      walk = lambda do |node|
        next unless node.is_a?(Prism::Node)
        next if node.type == :def_node

        if node.type == :call_node && (receiver = node.receiver)
          const = case receiver.type
                  when :local_variable_read_node then locals[receiver.name]
                  when :instance_variable_read_node then ivars[receiver.name]
                  when :call_node then built_class(receiver)
                  end
          found << [const, node.name] if const
        end
        node.compact_child_nodes.each { |child| walk.(child) }
      end
      walk.(body)
      found.uniq
    end

    def assignments(node, type, acc = [])
      return acc unless node.is_a?(Prism::Node)
      return acc if node.type == :def_node

      if node.type == type && (const = built_class(node.value))
        acc << [node.name, const]
      end
      node.compact_child_nodes.each { |child| assignments(child, type, acc) }
      acc
    end

    # The class text of Class.new(...), or nil.
    def built_class(node)
      return nil unless node&.type == :call_node && node.name == :new
      return nil unless %i[constant_read_node constant_path_node].include?(node.receiver&.type)

      node.receiver.slice.delete_prefix("::")
    end

    # Methods a class method calls on an instance it builds itself, as in
    # new(doc).apply, or new(path).tap(&:parse).
    def calls_on_new(node, acc = [])
      return acc unless node.is_a?(Prism::Node)
      return acc if node.type == :def_node

      if node.type == :call_node && node.receiver&.type == :call_node
        maker = node.receiver
        acc << called_on_receiver(node) if maker.name == :new && (maker.receiver.nil? || maker.receiver.type == :self_node)
      end
      node.compact_child_nodes.each { |child| calls_on_new(child, acc) }
      acc
    end

    # tap(&:parse) and then(&:parse) call parse on the receiver.
    def called_on_receiver(call)
      block = call.block
      return call.name unless %i[tap then].include?(call.name) && block&.type == :block_argument_node

      block.expression&.type == :symbol_node ? block.expression.unescaped.to_sym : call.name
    end

    def walk_evidence(node, evidence)
      return unless node.is_a?(Prism::Node)
      return if node.type == :def_node

      if node.type == :call_node
        note_call(node, evidence)
      elsif node.type == :case_node || node.type == :case_match_node
        note_case(node, evidence)
      end
      node.compact_child_nodes.each { |child| walk_evidence(child, evidence) }
    end

    def note_case(node, evidence)
      name = lvar_name(node.predicate)
      return unless name

      node.conditions.each do |when_node|
        next unless when_node.respond_to?(:conditions)

        Array(when_node.conditions).each do |condition|
          case condition.type
          when :string_node then evidence[name][:string] += 1
          when :integer_node then evidence[name][:int] += 1
          when :float_node then evidence[name][:float] += 1
          end
        end
      end
    end

    def note_call(node, evidence)
      receiver_name = lvar_name(node.receiver)
      op = node.name
      if receiver_name
        if STRING_METHODS.include?(op) || (op == :count && contains?(node, :string_node))
          evidence[receiver_name][:string] += 1
        elsif ARRAY_METHODS.include?(op)
          evidence[receiver_name][:array] += 1
        elsif HASH_METHODS.include?(op)
          evidence[receiver_name][:hash] += 1
        elsif NUMERIC_OPS.include?(op)
          arg = first_arg(node)
          if contains?(arg, :float_node)
            evidence[receiver_name][:float] += 1
          elsif contains?(arg, :string_node)
            evidence[receiver_name][:string] += 1
          else
            evidence[receiver_name][:int] += 1
          end
        end
      end

      return unless NUMERIC_OPS.include?(op)

      Array(node.arguments&.arguments).each do |arg|
        name = lvar_name(arg)
        next unless name

        if contains?(node.receiver, :float_node)
          evidence[name][:float] += 1
        elsif contains?(node.receiver, :string_node)
          evidence[name][:string] += 1
        elsif contains?(node.receiver, :integer_node) || node.receiver&.type == :integer_node
          evidence[name][:int] += 1
        end
      end
    end

    def first_arg(node)
      node.arguments&.arguments&.first
    end

    def lvar_name(node)
      return unless node.is_a?(Prism::Node) && node.type == :local_variable_read_node

      node.name
    end

    def contains?(node, type)
      return false unless node.is_a?(Prism::Node)
      return true if node.type == type

      node.compact_child_nodes.any? { |child| contains?(child, type) }
    end

    # A container default stands in as an empty one of its kind: the type is
    # what inference needs, and every mutated input passes the slot anyway.
    def literal_value(node)
      case node&.type
      when :integer_node then node.value
      when :float_node then node.value
      when :string_node then node.unescaped
      when :true_node then true
      when :false_node then false
      when :array_node then []
      when :hash_node then {}
      end
    end

    # functions tracks module_function and extend self in the current module
    # body: a bare module_function makes every later def a class method too,
    # named arguments make those defs class methods too, and extend self
    # makes every def in the body one, including those above it.
    def collect_defs(node, stack, in_singleton, acc, functions = nil)
      return unless node.is_a?(Prism::Node)

      case node.type
      when :module_node, :class_node
        inner = stack + [module_segment(node, stack)]
        @superclasses[inner.join("::")] = [stack, node.superclass.slice.delete_prefix("::")] if node.type == :class_node && node.superclass
        return unless node.body

        functions = { after: false, names: [], all: false }
        collect_defs(node.body, inner, false, acc, functions)
        named = acc.select do |info|
          info.const_name == inner.join("::") && !info.singleton &&
            (functions[:all] || functions[:names].include?(info.node.name))
        end
        named.each do |info|
          next if acc.any? { |other| other.singleton && other.node.equal?(info.node) }

          acc << DefInfo.new(const_name: info.const_name, singleton: true, node: info.node)
        end
      when :singleton_class_node
        collect_defs(node.body, stack, true, acc) if node.body
      when :def_node
        singleton = in_singleton || node.receiver&.type == :self_node
        acc << DefInfo.new(const_name: stack.join("::"), singleton: singleton, node: node)
        acc << DefInfo.new(const_name: stack.join("::"), singleton: true, node: node) if !singleton && functions&.dig(:after)
      else
        if functions && node.type == :call_node && node.name == :module_function && node.receiver.nil?
          arguments = node.arguments&.arguments
          functions[:after] = true unless arguments
          Array(arguments).each { |arg| functions[:names] << arg.unescaped.to_sym if arg.type == :symbol_node }
        end
        if functions && node.type == :call_node && node.name == :extend && node.receiver.nil? &&
           node.arguments&.arguments&.map(&:type) == [:self_node]
          functions[:all] = true
        end
        node.compact_child_nodes.each { |child| collect_defs(child, stack, in_singleton, acc, functions) }
      end
    end

    def source_line(line)
      source.lines[line - 1].to_s
    end

    def squash(text)
      text.to_s.gsub(/\s+/, " ").strip
    end
  end
end
