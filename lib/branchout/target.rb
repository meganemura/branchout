# frozen_string_literal: true
# rbs_inline: enabled

module Branchout
  # Static picture of one method: where it lives, which same-file callees it
  # reaches, the literals in that slice, and the condition text for each
  # decision Prism can see.
  class Target
    # +kind+ is a Ruby parameter kind (:req, :opt, :rest, :keyreq, :key).
    # +inferred_type+ is an input type name such as "int", or nil before
    # inference.
    Parameter = Struct.new(
      :kind, #: Symbol
      :name, #: Symbol
      :default, #: untyped
      :inferred_type, #: String?
      keyword_init: true
    )
    Literals = Struct.new(
      :ints, #: Array[Integer]
      :floats, #: Array[Float]
      :strings, #: Array[String]
      keyword_init: true
    )
    DefInfo = Struct.new(
      :const_name, #: String
      :singleton, #: bool
      :node, #: untyped
      keyword_init: true
    )
    # An operator that branches where branch coverage counts no arm.
    Operator = Struct.new(
      :loc, #: String
      :line, #: Integer
      :column, #: Integer
      :op, #: String
      :text, #: String
      keyword_init: true
    )

    STRING_METHODS = %i[
      include? start_with? end_with? split strip lstrip rstrip chomp
      match match? gsub sub scan upcase downcase chars to_i to_sym
      index rindex
    ].freeze #: Array[Symbol]
    ARRAY_METHODS = %i[each map select reject first last flatten flat_map].freeze #: Array[Symbol]
    HASH_METHODS = %i[keys values fetch each_pair key? value? merge].freeze #: Array[Symbol]
    NUMERIC_OPS = %i[+ - * / % == != < <= > >=].freeze #: Array[Symbol]

    ENTRY_RE = /\A([A-Z][A-Za-z0-9_]*(?:::[A-Z][A-Za-z0-9_]*)*)([.#])([A-Za-z_][A-Za-z0-9_]*[?!=]?)\z/ #: Regexp

    attr_reader :path #: String
    attr_reader :display_path #: String
    attr_reader :source #: String
    attr_reader :const_name #: String
    attr_reader :method_name #: Symbol
    attr_reader :singleton #: bool
    attr_reader :parameters #: Array[Parameter]
    attr_reader :constructor #: Array[Parameter]
    attr_reader :ranges #: Array[Range[Integer]]
    attr_reader :literals #: Literals
    attr_reader :entry #: String
    # [singleton, name] of each call on self that no method in this file
    # answers. Ruby's own lookup decides after load where each one lives.
    attr_reader :outside_calls #: Array[[bool, Symbol]]
    # [namespace, class, name] of each call on an object the counted code
    # builds with Class.new, kept in a local or an instance variable.
    # +class+ is the constant as written, so Ruby resolves it in +namespace+.
    attr_reader :typed_calls #: Array[[String, String, Symbol]]
    # Each ||, &&, ||=, and &&= of the counted code. Coverage sees no side of
    # them, so a method that branches only through them has no arm at all.
    # An @ivar ||= or &&= on an ivar the file writes nowhere else is left
    # out: it memoizes across calls on one object, and each input builds
    # its own receiver, so no input can vary its left side.
    attr_reader :operators #: Array[Operator]
    # Each @ivar ||= or &&= that OPERATORS leaves out, for the hint on a
    # method whose only branch is a memo.
    attr_reader :memos #: Array[Operator]
    # Each if or unless on defined?(@ivar), a memo that caches nil and
    # false too. Coverage counts its arms, but an input reaches the cached
    # arm only after a call on the same object, through setup, and then
    # returns what the first call stored, so a covered memo pins the same
    # value as no memo at all.
    attr_reader :defined_memos #: Array[Operator]
    # Each <, <=, >, and >= of the counted code. Coverage sees no side of
    # them either, so every arm can be taken with no input where the sides
    # are equal, where > and >= part.
    attr_reader :boundaries #: Array[Operator]

    ENUMERABLE_CALLS = Enumerable.instance_methods.to_set.freeze #: Set[Symbol]

    # @rbs @type_overrides: Array[String]?
    # @rbs @superclasses: Hash[String, [Array[String], String]]
    # @rbs @constant_values: Hash[Symbol, Array[untyped]]
    # @rbs @conditions: Hash[[Integer, Integer], untyped]

    # @rbs!
    #   # Evidence of each parameter's type: parameter name => type name => score.
    #   type evidence = Hash[Symbol?, Hash[Symbol, Integer]]

    #: (String, String, ?type_overrides: Array[String]?) -> Target
    def self.parse(path, entry, type_overrides: nil)
      new(path, entry, type_overrides: type_overrides).tap(&:parse)
    end

    #: (String, String, ?type_overrides: Array[String]?) -> void
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

    #: () -> self
    def parse
      result = Prism.parse(source)
      unless result.success?
        message = result.errors.map(&:message).join("; ")
        raise Error, "failed to parse #{display_path}: #{message}"
      end

      defs = [] #: Array[DefInfo]
      @superclasses = {}
      @constant_values = Hash.new { |hash, key| hash[key] = [] }
      collect_defs(result.value, [], false, defs)
      index = {} #: Hash[[String, bool, Symbol], DefInfo]
      defs.each do |info|
        key = [info.const_name, info.singleton, info.node.name] #: [String, bool, Symbol]
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
      argument_edges = [] #: Array[[untyped, untyped]]
      @typed_calls = []
      @literals = Literals.new(ints: [], floats: [], strings: [])
      @conditions = {}
      bodies = [] #: Array[untyped]
      seen = {} #: Hash[DefInfo, bool]
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
        built = info.singleton ? {} : built_ivars(defs, info.const_name) #: Hash[Symbol, String]
        calls_on_built(body, built).each { |const, name| @typed_calls << [info.const_name, const, name] } if body
        bare_calls(body).each do |call|
          callee = find.(info.singleton, call.name)
          if callee
            queue << callee
            argument_edges << [call, callee.node.parameters]
          else
            @outside_calls << [info.singleton, call.name]
            # Enumerable's methods are C, so they hide no arms of their own,
            # but they run the each this file defines.
            each = find.(info.singleton, :each) if ENUMERABLE_CALLS.include?(call.name)
            queue << each if each
          end
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

      written = ivars_written(result.value)
      @operators = bodies.flat_map { |body| operators_in(body, written) }.sort_by { |found| [found.line, found.column] }
      @memos = bodies.flat_map { |body| operators_in(body, written, memos: true) }.sort_by { |found| [found.line, found.column] }
      @boundaries = bodies.flat_map { |body| boundaries_in(body) }.sort_by { |found| [found.line, found.column] }
      @defined_memos = bodies.flat_map { |body| defined_memos_in(body, written) }.sort_by { |found| [found.line, found.column] }
      collect_literals(entry_def.node.parameters)
      bodies.each { |body| collect_literals(body) }
      @literals.ints = @literals.ints.uniq.sort
      @literals.floats = @literals.floats.uniq.sort
      @literals.strings = @literals.strings.uniq.sort
      @parameters = build_parameters(entry_def.node.parameters, bodies, @type_overrides, argument_edges)
      # The parameters of initialize, which an input's "new" fills for an
      # instance method. Empty when this file does not define initialize.
      init = singleton ? nil : index[[const_name, false, :initialize]]
      @constructor = init ? build_parameters(init.node.parameters, [init.node.body].compact, nil) : []
      self
    end

    #: () -> Array[Parameter]
    def positional
      parameters.select { |param| param.kind == :req || param.kind == :opt }
    end

    #: (Integer) -> bool
    def covers_line?(line)
      ranges.any? { |range| range.cover?(line) }
    end

    #: (Symbol, Integer, Integer, Symbol, Integer, Integer) -> String
    def condition_text(branch_type, bline, bcol, arm_type, aline, acol)
      node = @conditions[[bline, bcol]]
      text = condition_from(node, arm_type, aline, acol) if node
      text = squash(source_line(bline)) if text.nil? || text.empty?
      cut(text)
    end

    # An arm as a reviewer reads it, as its line and text: the keyword as
    # written (elsif, a modifier unless), the condition, and the arm. A case
    # arm sits on its when, in, or else line, and its condition already names
    # it (when 1, case x else). A ternary is written whole.
    #: (Symbol, Integer, Integer, Symbol, Integer, Integer) -> [Integer, String]
    def covered_arm(branch_type, bline, bcol, arm_type, aline, acol)
      cond = condition_text(branch_type, bline, bcol, arm_type, aline, acol)
      node = @conditions[[bline, bcol]]
      case branch_type
      when :case then [case_arm_line(node, arm_type, aline, acol) || bline, cond]
      when :"&." then [bline, "#{cond} -> &. receiver #{arm_type == :then ? "present" : "nil"}"]
      else
        keyword = if node.nil? then branch_type.to_s
                  elsif node.respond_to?(:if_keyword) then node.if_keyword
                  else node.keyword
                  end
        [bline, "#{keyword ? "#{keyword} #{cond}" : squash(node.slice)} -> #{arm_type}"]
      end
    end

    #: (String) -> String
    def self.display_path(path)
      absolute = File.expand_path(path)
      root = "#{File.expand_path(Dir.pwd)}/"
      return absolute.delete_prefix(root) if absolute.start_with?(root)

      absolute
    end

    # The lines of the def that starts on +line+ of +path+, or nil when no
    # def starts there, as with define_method.
    #: (String, Integer) -> Range[Integer]?
    def self.def_lines(path, line)
      stack = [Prism.parse(File.read(path)).value] #: Array[untyped]
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

    #: (untyped, Array[untyped], Array[String]?, ?Array[[untyped, untyped]]) -> Array[Parameter]
    def build_parameters(params_node, bodies, type_overrides, argument_edges = [])
      list = [] #: Array[Parameter]
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
      # Reversed, so a helper's helper passes its evidence up the chain first.
      argument_edges.reverse_each { |call, params| pass_evidence(call, params, evidence) }
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
    #: (String, Array[DefInfo]) -> Array[String]
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

    # The namespace a class or module body opens: class Cart::Line inside
    # module Shop is Shop::Cart::Line, and class ::Top is Top anywhere.
    #: (untyped, Array[String]) -> Array[String]
    def namespace_of(node, stack)
      path = node.constant_path.slice
      path.start_with?("::") ? [path.delete_prefix("::")] : stack + [path]
    end

    #: (Parameter, Hash[Symbol, Integer]) -> String
    def choose_type(param, scores)
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

    #: (untyped) -> String?
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

    #: (untyped, Symbol, Integer, Integer) -> String?
    def condition_from(node, arm_type, aline, acol)
      case node.type
      when :if_node, :unless_node, :while_node, :until_node
        squash(node.predicate&.slice)
      when :case_node, :case_match_node
        if arm_type == :when || arm_type == :in
          found = case_arm(node, aline, acol)
          found ? squash(found.slice.lines.first) : nil
        else
          node.predicate ? "case #{squash(node.predicate.slice)} else" : "case else"
        end
      end
    end

    #: (untyped, Integer, Integer) -> untyped
    def case_arm(node, aline, acol)
      node.conditions.find { |when_node| arm_matches?(when_node, aline, acol) }
    end

    # Coverage places a case arm at its body, not at its keyword.
    #: (untyped, Symbol, Integer, Integer) -> Integer?
    def case_arm_line(node, arm_type, aline, acol)
      return unless node

      # prism before 1.0, the default gem of Ruby 3.3, names the else clause consequent.
      else_clause = node.respond_to?(:else_clause) ? node.else_clause : node.consequent
      arm = arm_type == :else ? else_clause : case_arm(node, aline, acol)
      arm&.location&.start_line
    end

    # Coverage places a when or in arm at its body, or, when the body is
    # empty, at the keyword. Ruby 3.3 puts an empty in arm at the end of its
    # pattern instead.
    #: (untyped, Integer, Integer) -> bool
    def arm_matches?(when_node, aline, acol)
      arm = [aline, acol]
      body = when_node.statements&.location
      return [body.start_line, body.start_column] == arm if body

      keyword = when_node.location
      pattern = when_node.pattern.location if when_node.type == :in_node
      [keyword.start_line, keyword.start_column] == arm || (pattern && [pattern.end_line, pattern.end_column] == arm)
    end

    #: (untyped) -> void
    def index_conditions(node)
      return if node.type == :def_node

      if condition_node?(node)
        loc = node.location
        @conditions[[loc.start_line, loc.start_column]] = node
      end
      node.compact_child_nodes.each { |child| index_conditions(child) }
    end

    #: (untyped) -> bool
    def condition_node?(node)
      %i[if_node unless_node while_node until_node case_node case_match_node].include?(node.type)
    end

    # The instance variables the file sets other than with ||= or &&=.
    #: (untyped, ?Array[Symbol]) -> Array[Symbol]
    def ivars_written(node, acc = [])
      acc << node.name if %i[instance_variable_write_node instance_variable_operator_write_node instance_variable_target_node].include?(node.type)
      node.compact_child_nodes.each { |child| ivars_written(child, acc) }
      acc
    end

    # +memos+ picks the memos instead of the operators.
    #: (untyped, Array[Symbol], ?Array[Operator], ?memos: bool) -> Array[Operator]
    def operators_in(node, written, acc = [], memos: false)
      return acc if node.type == :def_node

      memo = %i[instance_variable_or_write_node instance_variable_and_write_node].include?(node.type) && !written.include?(node.name)
      branching = node.type == :or_node || node.type == :and_node || node.type.to_s.end_with?("_or_write_node", "_and_write_node")
      if branching && memo == memos
        operator = node.operator_loc
        line = operator.start_line
        column = operator.start_column
        acc << Operator.new(loc: "#{display_path}:#{line}:#{column}", line: line, column: column, op: operator.slice,
                            text: cut(squash(node.slice)))
      end
      node.compact_child_nodes.each { |child| operators_in(child, written, acc, memos: memos) }
      acc
    end

    COMPARISONS = %i[< <= > >=].freeze #: Array[Symbol]

    #: (untyped, ?Array[Operator]) -> Array[Operator]
    def boundaries_in(node, acc = [])
      return acc if node.type == :def_node

      if node.type == :call_node && COMPARISONS.include?(node.name) && node.receiver && node.arguments&.arguments&.length == 1
        operator = node.message_loc
        acc << Operator.new(loc: "#{display_path}:#{operator.start_line}:#{operator.start_column}", line: operator.start_line,
                            column: operator.start_column, op: operator.slice, text: cut(squash(node.slice)))
      end
      node.compact_child_nodes.each { |child| boundaries_in(child, acc) }
      acc
    end

    # Each if or unless on defined?(@ivar) of an ivar the file sets, as in
    # return @value if defined?(@value).
    #: (untyped, Array[Symbol], ?Array[Operator]) -> Array[Operator]
    def defined_memos_in(node, written, acc = [])
      return acc if node.type == :def_node

      predicate = node.predicate if %i[if_node unless_node].include?(node.type)
      if predicate&.type == :defined_node && predicate.value.type == :instance_variable_read_node && written.include?(predicate.value.name)
        place = predicate.location
        acc << Operator.new(loc: "#{display_path}:#{place.start_line}:#{place.start_column}", line: place.start_line,
                            column: place.start_column, op: "defined?", text: cut(squash(node.slice)))
      end
      node.compact_child_nodes.each { |child| defined_memos_in(child, written, acc) }
      acc
    end

    #: (untyped) -> void
    def collect_literals(node)
      return unless node.is_a?(Prism::Node)
      return if node.type == :def_node

      case node.type
      # is_a? narrows the node to Prism::Node, which declares no method of a
      # node type, so steep cannot see the methods each type has.
      when :integer_node
        @literals.ints << node.value # steep:ignore NoMethod
      when :float_node
        # 1e400 parses to Infinity, which JSON cannot write as an input.
        @literals.floats << node.value if node.value.finite? # steep:ignore NoMethod
      when :string_node
        @literals.strings << node.unescaped # steep:ignore NoMethod
      when :constant_read_node
        Array(@constant_values[node.name]).each { |value| collect_literals(value) } # steep:ignore NoMethod
      end
      node.compact_child_nodes.each { |child| collect_literals(child) }
    end

    #: (untyped, ?Array[untyped]) -> Array[untyped]
    def bare_calls(node, acc = [])
      return acc unless node.is_a?(Prism::Node)
      return acc if node.type == :def_node

      if node.type == :call_node
        receiver = node.receiver # steep:ignore NoMethod
        acc << node if receiver.nil? || receiver.type == :self_node
      end
      node.compact_child_nodes.each { |child| bare_calls(child, acc) }
      acc
    end

    # Instance variables that a method of +const+ in this file sets to
    # Class.new, as initialize does for a collaborator: name => class text.
    #: (Array[DefInfo], String) -> Hash[Symbol, String]
    def built_ivars(defs, const)
      defs.select { |info| info.const_name == const && !info.singleton && info.node.body }
          .flat_map { |info| assignments(info.node.body, :instance_variable_write_node) }.to_h
    end

    # [class text, method name] of each call on a value that this body
    # builds with Class.new: a local it assigns, an instance variable in
    # +ivars+, or the new call itself.
    #: (untyped, Hash[Symbol, String]) -> Array[[String, Symbol]]
    def calls_on_built(body, ivars)
      locals = assignments(body, :local_variable_write_node).to_h
      found = [] #: Array[[String, Symbol]]
      walk = lambda do |node|
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

    #: (untyped, Symbol, ?Array[[Symbol, String]]) -> Array[[Symbol, String]]
    def assignments(node, type, acc = [])
      return acc if node.type == :def_node

      if node.type == type && (const = built_class(node.value))
        acc << [node.name, const]
      end
      node.compact_child_nodes.each { |child| assignments(child, type, acc) }
      acc
    end

    # The class text of Class.new(...), or nil.
    #: (untyped) -> String?
    def built_class(node)
      return nil unless node&.type == :call_node && node.name == :new
      return nil unless %i[constant_read_node constant_path_node].include?(node.receiver&.type)

      node.receiver.slice.delete_prefix("::")
    end

    # Methods a class method calls on an instance it builds itself, as in
    # new(doc).apply, or new(path).tap(&:parse).
    #: (untyped, ?Array[Symbol]) -> Array[Symbol]
    def calls_on_new(node, acc = [])
      return acc unless node.is_a?(Prism::Node)
      return acc if node.type == :def_node

      if node.type == :call_node && node.receiver&.type == :call_node # steep:ignore NoMethod
        maker = node.receiver # steep:ignore NoMethod
        acc << called_on_receiver(node) if maker.name == :new && (maker.receiver.nil? || maker.receiver.type == :self_node)
      end
      node.compact_child_nodes.each { |child| calls_on_new(child, acc) }
      acc
    end

    # tap(&:parse) and then(&:parse) call parse on the receiver.
    #: (untyped) -> Symbol
    def called_on_receiver(call)
      block = call.block
      return call.name unless %i[tap then].include?(call.name) && block&.type == :block_argument_node

      block.expression&.type == :symbol_node ? block.expression.unescaped.to_sym : call.name
    end

    #: (untyped, evidence) -> void
    def walk_evidence(node, evidence)
      return if node.type == :def_node

      if node.type == :call_node
        note_call(node, evidence)
      elsif node.type == :case_node || node.type == :case_match_node
        note_case(node, evidence)
      end
      node.compact_child_nodes.each { |child| walk_evidence(child, evidence) }
    end

    #: (untyped, evidence) -> void
    def note_case(node, evidence)
      name = lvar_name(node.predicate)
      return unless name

      node.conditions.each do |when_node|
        next unless when_node.respond_to?(:conditions)

        Array(when_node.conditions).each do |condition|
          # @type var condition: untyped
          case condition.type
          when :string_node then evidence[name][:string] += 1
          when :integer_node then evidence[name][:int] += 1
          when :float_node then evidence[name][:float] += 1
          end
        end
      end
    end

    #: (untyped, evidence) -> void
    def note_call(node, evidence)
      receiver_name = lvar_name(node.receiver)
      op = node.name
      if receiver_name
        if STRING_METHODS.include?(op) || (op == :count && contains?(node, :string_node))
          evidence[receiver_name][:string] += 1
        elsif ARRAY_METHODS.include?(op)
          evidence[receiver_name][:array] += 1
        elsif HASH_METHODS.include?(op) || (%i[[] dig].include?(op) && %i[string_node symbol_node].include?(first_arg(node)&.type))
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
        elsif contains?(node.receiver, :integer_node)
          evidence[name][:int] += 1
        end
      end
    end

    # held?(code) with def held?(state) = state == "held" makes code a
    # String too: a positional argument takes the evidence of the
    # parameter it fills.
    #: (untyped, untyped, evidence) -> void
    def pass_evidence(call, params, evidence)
      return unless params

      names = (params.requireds + params.optionals).map { |param| param.name if param.respond_to?(:name) }
      Array(call.arguments&.arguments).each_with_index do |arg, index|
        # @type var arg: untyped
        # Past a splat, an argument's position no longer names its parameter.
        break if arg.type == :splat_node

        name = lvar_name(arg)
        evidence[names[index]].each { |kind, count| evidence[name][kind] += count } if name
      end
    end

    #: (untyped) -> untyped
    def first_arg(node)
      node.arguments&.arguments&.first
    end

    #: (untyped) -> Symbol?
    def lvar_name(node)
      return unless node.is_a?(Prism::Node) && node.type == :local_variable_read_node

      node.name # steep:ignore NoMethod
    end

    #: (untyped, Symbol) -> bool
    def contains?(node, type)
      return false unless node.is_a?(Prism::Node)
      return true if node.type == type
      return true if node.type == :constant_read_node && Array(@constant_values[node.name]).any? { |value| value.type == type } # steep:ignore NoMethod

      node.compact_child_nodes.any? { |child| contains?(child, type) }
    end

    # A container default stands in as an empty one of its kind: the type is
    # what inference needs, and every mutated input passes the slot anyway.
    #: (untyped) -> (Integer | Float | String | bool | Array[untyped] | Hash[untyped, untyped] | nil)
    def literal_value(node)
      case node&.type
      when :integer_node then node.value
      when :float_node then node.value
      when :string_node then node.unescaped
      when :true_node then true
      when :false_node then false
      when :array_node then []
      when :hash_node then {} #: Hash[untyped, untyped]
      end
    end

    # functions tracks module_function and extend self in the current module
    # body: a bare module_function makes every later def a class method too,
    # named arguments make those defs class methods too, and extend self
    # makes every def in the body one, including those above it.
    #: (untyped, Array[String], bool, Array[DefInfo], ?{ after: bool, names: Array[Symbol], all: bool }?) -> void
    def collect_defs(node, stack, in_singleton, acc, functions = nil)
      case node.type
      when :module_node, :class_node
        inner = namespace_of(node, stack)
        @superclasses[inner.join("::")] = [stack, node.superclass.slice.delete_prefix("::")] if node.type == :class_node && node.superclass
        return unless node.body

        functions = { after: false, names: [], all: false } #: { after: bool, names: Array[Symbol], all: bool }
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
      when :constant_write_node, :constant_path_write_node
        body = class_block_body(node.value)
        name = node.type == :constant_write_node ? node.name.to_s : node.target.slice.delete_prefix("::")
        note_constant(node) if node.type == :constant_write_node
        body ? collect_defs(body, stack + [name], false, acc) : collect_defs(node.value, stack, in_singleton, acc, functions)
      when :def_node
        singleton = in_singleton || node.receiver&.type == :self_node
        acc << DefInfo.new(const_name: stack.join("::"), singleton: singleton, node: node)
        acc << DefInfo.new(const_name: stack.join("::"), singleton: true, node: node) if !singleton && functions&.dig(:after)
      else
        if functions && node.type == :call_node && node.name == :module_function && node.receiver.nil?
          arguments = node.arguments&.arguments
          functions[:after] = true unless arguments
          Array(arguments).each { |arg| functions[:names] << arg.unescaped.to_sym if arg.type == :symbol_node } # steep:ignore NoMethod
        end
        if functions && node.type == :call_node && node.name == :extend && node.receiver.nil? &&
           node.arguments&.arguments&.map(&:type) == [:self_node]
          functions[:all] = true
        end
        node.compact_child_nodes.each { |child| collect_defs(child, stack, in_singleton, acc, functions) }
      end
    end

    # NAME = literal, by name alone: a helper's comparison against CLOSED is
    # a comparison against its literal, wherever the file sets CLOSED.
    #: (untyped) -> void
    def note_constant(node)
      value = node.value
      value = value.receiver if value.type == :call_node && value.name == :freeze && value.receiver
      @constant_values[node.name] << value if %i[integer_node float_node string_node].include?(value&.type)
    end

    # The body of the block in Struct.new(...) do ... end, Data.define, or
    # Class.new, whose defs are methods of the class the call builds.
    CLASS_BUILDERS = { "Struct" => :new, "Data" => :define, "Class" => :new }.freeze #: Hash[String, Symbol]

    #: (untyped) -> untyped
    def class_block_body(value)
      return unless value.type == :call_node && value.block&.type == :block_node && value.receiver

      receiver = value.receiver.slice.delete_prefix("::")
      value.block.body if CLASS_BUILDERS[receiver] == value.name
    end

    #: (Integer) -> String
    def source_line(line)
      source.lines[line - 1].to_s
    end

    #: (String) -> String
    def cut(text) = text.length > 160 ? "#{text[0, 157]}..." : text

    #: (untyped) -> String
    def squash(text)
      text.to_s.gsub(/\s+/, " ").strip
    end
  end
end
