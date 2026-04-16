# frozen_string_literal: true

module ImportExport
  # Finds an existing record matching the given row on configured match fields.
  # Always queries via the company-scoped relation (never bypasses tenancy).
  class DuplicateDetector
    def initialize(scope, match_fields)
      @scope = scope
      @match_fields = Array(match_fields).map(&:to_s)
    end

    def find(row_data)
      return nil if @match_fields.empty?

      conditions = @match_fields.each_with_object({}) do |field, h|
        v = row_data[field]
        h[field] = v if v.present?
      end
      return nil if conditions.empty?

      @scope.where(conditions).first
    end
  end
end
