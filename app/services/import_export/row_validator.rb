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
      when 'integer'
        cleaned = value.to_s.gsub(/[^\d\-]/, '')
        return nil if cleaned.empty?
        Integer(cleaned)
      when 'decimal', 'currency', 'percent', 'number'
        cleaned = value.to_s.gsub(/[^\d\.\-]/, '')
        return nil if cleaned.empty?
        Float(cleaned)
      when 'boolean', 'checkbox'
        s = value.to_s.strip.downcase
        return true  if TRUE_VALUES.include?(s)
        return false if FALSE_VALUES.include?(s)
        raise "invalid boolean: #{value}"
      when 'date'
        value.is_a?(Date) ? value : parse_flexible_date(value.to_s)
      when 'datetime'
        value.is_a?(Time) ? value : parse_flexible_datetime(value.to_s)
      when 'json'
        value.is_a?(Hash) || value.is_a?(Array) ? value : JSON.parse(value.to_s)
      when 'multiselect'
        value.is_a?(Array) ? value : value.to_s.split(/[,;|]/).map(&:strip).reject(&:empty?)
      else
        value.to_s
      end
    end

    # Handles common date formats: M/D/YYYY, MM/DD/YYYY, YYYY-MM-DD, D-Mon-YYYY, etc.
    DATE_FORMATS = [
      '%m/%d/%Y',   # 2/25/2026 or 02/25/2026
      '%m-%d-%Y',   # 02-25-2026
      '%Y-%m-%d',   # 2026-02-25 (ISO)
      '%Y/%m/%d',   # 2026/02/25
      '%d/%m/%Y',   # 25/02/2026 (EU — tried last to prefer US)
      '%b %d, %Y',  # Feb 25, 2026
      '%B %d, %Y',  # February 25, 2026
      '%d-%b-%Y',   # 25-Feb-2026
    ].freeze

    def parse_flexible_date(str)
      s = str.strip
      DATE_FORMATS.each do |fmt|
        return Date.strptime(s, fmt)
      rescue ArgumentError
        next
      end
      # Final fallback to Ruby's built-in parser
      Date.parse(s)
    rescue ArgumentError
      raise "invalid date: #{str}"
    end

    def parse_flexible_datetime(str)
      s = str.strip
      # Try Time.zone.parse first (handles ISO 8601, most standard formats)
      parsed = Time.zone.parse(s) rescue nil
      return parsed if parsed

      # Try date-only formats and convert to beginning of day
      date = parse_flexible_date(s) rescue nil
      return date.beginning_of_day if date

      raise "invalid datetime: #{str}"
    end
  end
end
