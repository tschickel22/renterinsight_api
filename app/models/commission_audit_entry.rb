class CommissionAuditEntry < ApplicationRecord
  belongs_to :commission
  belongs_to :user

  ACTIONS = %w[created updated approved rejected paid cancelled].freeze

  validates :action, inclusion: { in: ACTIONS }

  default_scope { order(created_at: :desc) }

  # Get formatted action display text
  def action_display
    case action
    when 'created' then 'Created'
    when 'updated' then 'Updated'
    when 'approved' then 'Approved'
    when 'rejected' then 'Rejected'
    when 'paid' then 'Marked as Paid'
    when 'cancelled' then 'Cancelled'
    else action.titleize
    end
  end

  # Get changes summary
  def changes_summary
    return nil unless previous_value.present? && new_value.present?

    changes = []
    new_value.each do |key, new_val|
      old_val = previous_value[key]
      changes << "#{key.titleize}: #{old_val} → #{new_val}" if old_val != new_val
    end
    changes.join(', ')
  end
end
