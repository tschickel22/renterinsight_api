# frozen_string_literal: true

# Saved report definition. The `config` JSONB column stores the runtime
# parameters that get passed to ReportEngine.run, e.g.:
#
#   {
#     fields:     ['id', 'first_name', ...],
#     filters:    { date_range: { field:, from:, to: }, where: [...] },
#     group_by:   nil,
#     sort_by:    'created_at',
#     sort_order: 'desc',
#     page:       1,
#     per_page:   50
#   }
class Report < ApplicationRecord
  belongs_to :company
  belongs_to :user, optional: true

  VISIBILITY_OPTIONS = %w[private location company platform].freeze

  validates :name, :module_key, presence: true
  validates :visibility, inclusion: { in: VISIBILITY_OPTIONS }, allow_nil: true

  scope :active, -> { where(is_deleted: [false, nil]) }

  # Returns array of user IDs who have been explicitly shared with
  def shared_user_ids_array
    ids = shared_user_ids
    return [] if ids.blank?
    ids.is_a?(Array) ? ids.map(&:to_i) : []
  end
end
