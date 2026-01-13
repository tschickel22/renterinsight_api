class Commission < ApplicationRecord
  belongs_to :company
  belongs_to :deal
  belongs_to :user  # sales rep who earned the commission
  belongs_to :commission_rule, optional: true
  belongs_to :location, optional: true
  has_many :audit_entries, class_name: 'CommissionAuditEntry', dependent: :destroy

  TYPES = %w[flat percentage tiered].freeze
  STATUSES = %w[pending approved paid cancelled].freeze

  validates :commission_type, inclusion: { in: TYPES }
  validates :status, inclusion: { in: STATUSES }
  validates :amount, presence: true, numericality: { greater_than_or_equal_to: 0 }

  # Location filtering scope
  scope :for_current_location, -> {
    Current.location_filtered? ? where(location_id: Current.location_id) : all
  }

  # Status scopes
  scope :pending, -> { where(status: 'pending') }
  scope :approved, -> { where(status: 'approved') }
  scope :paid, -> { where(status: 'paid') }
  scope :cancelled, -> { where(status: 'cancelled') }

  # Approve commission
  def approve!(approver_user, notes: nil)
    transaction do
      previous_status = status
      update!(status: 'approved')
      
      audit_entries.create!(
        user: approver_user,
        action: 'approved',
        previous_value: { status: previous_status },
        new_value: { status: 'approved' },
        notes: notes
      )
    end
  end

  # Reject commission
  def reject!(rejecter_user, notes: nil)
    transaction do
      previous_status = status
      update!(status: 'cancelled')
      
      audit_entries.create!(
        user: rejecter_user,
        action: 'rejected',
        previous_value: { status: previous_status },
        new_value: { status: 'cancelled' },
        notes: notes
      )
    end
  end

  # Mark commission as paid
  def mark_paid!(payer_user, notes: nil)
    transaction do
      previous_status = status
      previous_paid_date = paid_date
      
      update!(status: 'paid', paid_date: Date.today)
      
      audit_entries.create!(
        user: payer_user,
        action: 'paid',
        previous_value: { status: previous_status, paid_date: previous_paid_date },
        new_value: { status: 'paid', paid_date: Date.today },
        notes: notes
      )
    end
  end

  # Track update with audit
  def update_with_audit!(attributes, updating_user, notes: nil)
    transaction do
      previous_values = self.slice(*attributes.keys.map(&:to_s))
      
      if update!(attributes)
        audit_entries.create!(
          user: updating_user,
          action: 'updated',
          previous_value: previous_values,
          new_value: attributes,
          notes: notes
        )
      end
    end
  end

  # Check if commission can be edited
  def can_edit?
    status == 'pending'
  end

  # Check if commission can be approved
  def can_approve?
    status == 'pending'
  end

  # Check if commission can be marked paid
  def can_mark_paid?
    status == 'approved'
  end

  # Check if commission can be cancelled
  def can_cancel?
    %w[pending approved].include?(status)
  end
end
