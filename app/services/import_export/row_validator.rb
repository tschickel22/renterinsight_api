# frozen_string_literal: true

module ImportExport
  # Validates a single row against module field definitions and coerces types.
  class RowValidator
    TRUE_VALUES  = %w[1 true t yes y on].freeze
    FALSE_VALUES = %w[0 false f no n off].freeze

    def initialize(fields)
      @fields = fields
      @by_key = fields.index_by { |f| f[:key] }
    end

    # row_data: { 'first_name' => 'Jane', ... } already keyed by db field
    def call(row_data)
      errors = []
      transformed = {}

      row_data.each do |key, raw|
        field = @by_key[key.to_s]
        next unless field

        begin
          transformed[key.to_s] = coerce(raw, field[:type])
        rescue StandardError => e
          errors << "#{field[:label] || key}: #{e.message}"
        end
      end

      @fields.select { |f| f[:required] }.each do |f|
        v = transformed[f[:key]]
        if v.nil? || (v.is_a?(String) && v.strip.empty?)
          errors << "#{f[:label] || f[:key]} is required"
        end
      end

      { valid: errors.empty?, errors: errors, transformed_data: transformed }
    end

    private

    def coerce(value, type)
      return nil if value.nil? || (value.is_a?(String) && value.strip.empty?)

      case type.to_s
      when 'integer'  then Integer(value.to_s.gsub(/[^\d\-]/, ''))
      when 'decimal', 'currency', 'percent', 'number'
        Float(value.to_s.gsub(/[^\d\.\-]/, ''))
      when 'boolean', 'checkbox'
        s = value.to_s.strip.downcase
        return true  if TRUE_VALUES.include?(s)
        return false if FALSE_VALUES.include?(s)
        raise "invalid boolean: #{value}"
      when 'date'
        value.is_a?(Date) ? value : Date.parse(value.to_s)
      when 'datetime'
        value.is_a?(Time) ? value : Time.zone.parse(value.to_s)
      when 'json'
        value.is_a?(Hash) || value.is_a?(Array) ? value : JSON.parse(value.to_s)
      when 'multiselect'
        value.is_a?(Array) ? value : value.to_s.split(/[,;|]/).map(&:strip).reject(&:empty?)
      else
        value.to_s
      end
    end
  end
end
