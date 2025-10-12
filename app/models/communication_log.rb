# frozen_string_literal: true
class CommunicationLog < ApplicationRecord
  self.table_name = 'communication_logs'
  belongs_to :lead, optional: true
  belongs_to :account, optional: true

  validates :comm_type, inclusion: { in: %w[email sms call note], allow_nil: true }
  validate :must_have_lead_or_account

  scope :for_lead, ->(lead_id) { where(lead_id: lead_id) }
  scope :for_account, ->(account_id) { where(account_id: account_id) }
  scope :recent,   -> { order(Arel.sql("COALESCE(sent_at, created_at) DESC")) }

  private

  def must_have_lead_or_account
    if lead_id.blank? && account_id.blank?
      errors.add(:base, 'Must belong to either a lead or an account')
    end
  end
end
