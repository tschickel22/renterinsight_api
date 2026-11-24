# frozen_string_literal: true

module Guide
  # Keeps what a tool hands the help assistant under a size limit by dropping
  # items from its longest lists, never by cutting text mid-way (which hands
  # Claude broken JSON). Says how many it left out, so the answer can say so.
  module Fit
    MAX_CHARS = 8_000

    module_function

    def call(value, max_chars: MAX_CHARS)
      value = value.deep_dup
      40.times do
        return value if value.to_json.length <= max_chars

        path, list = longest_list(value)
        break if list.nil? || list.size <= 1

        keep = [list.size / 2, 1].max
        dropped = list.size - keep
        list.slice!(keep..)
        note(value, path, dropped)
      end
      return value if value.to_json.length <= max_chars

      { too_large: true, note: 'The result was too large to read here. Ask about one record or a narrower question.' }
    end

    def longest_list(value, path = [])
      best = [nil, nil]
      walk(value, path) do |p, list|
        best = [p, list] if best[1].nil? || list.to_json.length > best[1].to_json.length
      end
      best
    end

    def walk(value, path, &block)
      case value
      when Array
        yield(path, value) if value.size > 1
        value.each_with_index { |v, i| walk(v, path + [i], &block) }
      when Hash
        value.each { |k, v| walk(v, path + [k], &block) }
      end
    end

    # Adds "<key>_left_out: n" beside the list when it sits in a Hash.
    def note(root, path, dropped)
      return if path.empty?

      parent = path[0..-2].reduce(root) { |node, key| node[key] }
      key = path.last
      return unless parent.is_a?(Hash)

      left_out_key = key.is_a?(Symbol) ? :"#{key}_left_out" : "#{key}_left_out"
      parent[left_out_key] = parent[left_out_key].to_i + dropped
    end
  end
end
