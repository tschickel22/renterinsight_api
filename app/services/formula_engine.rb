# frozen_string_literal: true

# FormulaEngine evaluates formula fields defined in custom_field_definitions.
# It is a pure computation engine — no side effects, no DB writes.
#
# Formula syntax: starts with '=', references field keys, supports +, -, *, /
# Functions: round(value, decimals), if(condition, true_val, false_val), percent_of(base, rate)
#
# Usage:
#   engine = FormulaEngine.new
#   result = engine.evaluate(field_definitions, field_values)
#   # => { 'sub_total_1' => 271166.0, 'cash_purchase_price' => 276480.98 }
class FormulaEngine
  class CircularDependencyError < StandardError; end
  class InvalidFormulaError < StandardError; end

  VALID_FIELD_TYPES = %w[text currency percentage number date select checkbox formula].freeze

  def evaluate(field_definitions, field_values)
    @definitions = normalize_definitions(field_definitions)
    @values = normalize_values(field_values)
    @formula_fields = @definitions.select { |d| d['formula'].present? && d['formula'].to_s.start_with?('=') }
    @results = {}

    order = topological_sort
    order.each do |key|
      defn = @formula_fields.find { |d| d['key'] == key }
      next unless defn

      raw = compute(defn['formula'][1..]) # strip leading '='
      @values[key] = raw
      @results[key] = raw.is_a?(BigDecimal) ? raw.to_f : raw
    end

    @results
  end

  # Validate a formula string against known field keys.
  # Returns { valid: true/false, error: 'msg', referenced_fields: [...] }
  def validate_formula(formula_str, available_keys)
    return { valid: false, error: 'Formula must start with =' } unless formula_str.to_s.start_with?('=')

    expr = formula_str[1..]
    refs = extract_references(expr)
    unknown = refs - available_keys.map(&:to_s)

    if unknown.any?
      return { valid: false, error: "Unknown field(s): #{unknown.join(', ')}", referenced_fields: refs }
    end

    # Try parsing to catch syntax errors
    tokenize(expr)
    { valid: true, error: nil, referenced_fields: refs }
  rescue InvalidFormulaError => e
    { valid: false, error: e.message, referenced_fields: refs || [] }
  end

  # Validate a single field value against its type definition
  def self.validate_value(value, field_def)
    return { valid: true } if value.nil? || value.to_s.strip.empty?

    type = field_def['type'] || field_def[:type]
    case type
    when 'currency', 'number'
      numeric = Float(value) rescue nil
      return { valid: false, error: "must be a number" } unless numeric
      { valid: true }
    when 'percentage'
      numeric = Float(value) rescue nil
      return { valid: false, error: "must be a number" } unless numeric
      if numeric < 0
        { valid: false, error: "must be 0 or greater" }
      else
        { valid: true, warning: "value exceeds 100%" } if numeric > 100
        { valid: true }
      end
    when 'date'
      Date.iso8601(value.to_s) rescue (return { valid: false, error: "must be a valid ISO 8601 date" })
      { valid: true }
    when 'select'
      options = field_def['options'] || field_def[:options] || []
      unless options.include?(value.to_s)
        return { valid: false, error: "must be one of: #{options.join(', ')}" }
      end
      { valid: true }
    when 'checkbox'
      unless [true, false, 'true', 'false', 1, 0, '1', '0'].include?(value)
        return { valid: false, error: "must be a boolean" }
      end
      { valid: true }
    when 'formula'
      { valid: true } # read-only, calculated
    when 'text'
      { valid: true }
    else
      { valid: true }
    end
  end

  private

  def normalize_definitions(defs)
    (defs || []).map { |d| d.is_a?(Hash) ? d.stringify_keys : d }
  end

  def normalize_values(vals)
    result = {}
    (vals || {}).each { |k, v| result[k.to_s] = v }
    result
  end

  def extract_references(expr)
    # Remove function names, numbers, operators, and parens to find field key references
    cleaned = expr.dup
    # Remove function calls (keep args)
    cleaned.gsub!(/\b(round|if|percent_of)\s*\(/, '(')
    # Remove numeric literals (including decimals)
    cleaned.gsub!(/\b\d+(\.\d+)?\b/, '')
    # Remove operators and parens
    cleaned.gsub!(/[+\-*\/(),<>=!&|]/, ' ')
    # Remove comparison keywords
    cleaned.gsub!(/\b(and|or|not)\b/i, '')
    cleaned.split.select { |token| token.match?(/\A[a-zA-Z_][a-zA-Z0-9_.]*\z/) }.uniq
  end

  # Build dependency graph and return topological order
  def topological_sort
    graph = {}
    @formula_fields.each do |defn|
      key = defn['key']
      refs = extract_references(defn['formula'][1..])
      formula_keys = @formula_fields.map { |d| d['key'] }
      # Only track dependencies on OTHER formula fields
      graph[key] = refs & formula_keys
    end

    visited = {}
    order = []
    in_progress = {}

    sort_visit = lambda do |node|
      return if visited[node]
      if in_progress[node]
        raise CircularDependencyError, "Circular dependency detected involving '#{node}'"
      end

      in_progress[node] = true
      (graph[node] || []).each { |dep| sort_visit.call(dep) }
      in_progress.delete(node)
      visited[node] = true
      order << node
    end

    graph.each_key { |node| sort_visit.call(node) }
    order
  end

  # Compute a formula expression string, returning a BigDecimal
  def compute(expr)
    tokens = tokenize(expr)
    result = parse_expression(tokens)
    raise InvalidFormulaError, "Unexpected tokens after expression: #{tokens.inspect}" unless tokens.empty?
    result
  end

  # Tokenizer
  def tokenize(expr)
    tokens = []
    scanner = StringScanner.new(expr.strip)

    until scanner.eos?
      scanner.skip(/\s+/)
      break if scanner.eos?

      if scanner.scan(/\d+(\.\d+)?/)
        tokens << { type: :number, value: BigDecimal(scanner.matched) }
      elsif scanner.scan(/[+\-]/)
        tokens << { type: :op, value: scanner.matched }
      elsif scanner.scan(/[*\/]/)
        tokens << { type: :op, value: scanner.matched }
      elsif scanner.scan(/<=|>=|!=|==|<|>/)
        tokens << { type: :comp, value: scanner.matched }
      elsif scanner.scan(/\(/)
        tokens << { type: :lparen, value: '(' }
      elsif scanner.scan(/\)/)
        tokens << { type: :rparen, value: ')' }
      elsif scanner.scan(/,/)
        tokens << { type: :comma, value: ',' }
      elsif scanner.scan(/[a-zA-Z_][a-zA-Z0-9_.]*/)
        tokens << { type: :identifier, value: scanner.matched }
      else
        raise InvalidFormulaError, "Unexpected character: '#{scanner.peek(1)}'"
      end
    end

    tokens
  end

  # Recursive descent parser: expression = term ((+|-) term)*
  def parse_expression(tokens)
    left = parse_term(tokens)

    while tokens.first && tokens.first[:type] == :op && ['+', '-'].include?(tokens.first[:value])
      op = tokens.shift[:value]
      right = parse_term(tokens)
      left = op == '+' ? left + right : left - right
    end

    left
  end

  # term = factor ((*|/) factor)*
  def parse_term(tokens)
    left = parse_factor(tokens)

    while tokens.first && tokens.first[:type] == :op && ['*', '/'].include?(tokens.first[:value])
      op = tokens.shift[:value]
      right = parse_factor(tokens)
      if op == '/'
        raise InvalidFormulaError, "Division by zero" if right.zero?
        left = left / right
      else
        left = left * right
      end
    end

    left
  end

  # factor = number | identifier | function_call | (expression) | -factor
  def parse_factor(tokens)
    token = tokens.first

    raise InvalidFormulaError, "Unexpected end of formula" unless token

    # Unary minus
    if token[:type] == :op && token[:value] == '-'
      tokens.shift
      return -parse_factor(tokens)
    end

    # Number literal
    if token[:type] == :number
      tokens.shift
      return token[:value]
    end

    # Parenthesized expression
    if token[:type] == :lparen
      tokens.shift
      result = parse_expression(tokens)
      expect_token(tokens, :rparen)
      return result
    end

    # Identifier (field reference or function call)
    if token[:type] == :identifier
      name = token[:value]
      tokens.shift

      # Check if it's a function call
      if tokens.first && tokens.first[:type] == :lparen
        return call_function(name, tokens)
      end

      # Field reference — look up value, treat nil/blank as 0
      return resolve_value(name)
    end

    raise InvalidFormulaError, "Unexpected token: #{token.inspect}"
  end

  def call_function(name, tokens)
    expect_token(tokens, :lparen)
    args = parse_args(tokens)
    expect_token(tokens, :rparen)

    case name
    when 'round'
      raise InvalidFormulaError, "round() requires 2 arguments" unless args.length == 2
      args[0].round(args[1].to_i)
    when 'if'
      raise InvalidFormulaError, "if() requires 3 arguments" unless args.length == 3
      # For if(), first arg is evaluated as condition: non-zero = true
      args[0] != 0 ? args[1] : args[2]
    when 'percent_of'
      raise InvalidFormulaError, "percent_of() requires 2 arguments" unless args.length == 2
      (args[0] * args[1]) / BigDecimal('100')
    else
      raise InvalidFormulaError, "Unknown function: #{name}"
    end
  end

  def parse_args(tokens)
    args = []
    return args if tokens.first && tokens.first[:type] == :rparen

    args << parse_expression(tokens)
    while tokens.first && tokens.first[:type] == :comma
      tokens.shift
      args << parse_expression(tokens)
    end
    args
  end

  def expect_token(tokens, type)
    token = tokens.shift
    raise InvalidFormulaError, "Expected #{type}, got #{token&.inspect || 'end of input'}" unless token && token[:type] == type
  end

  def resolve_value(key)
    val = @values[key]
    return BigDecimal('0') if val.nil? || val.to_s.strip.empty?

    BigDecimal(val.to_s)
  rescue ArgumentError
    BigDecimal('0')
  end
end
