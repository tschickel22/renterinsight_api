# frozen_string_literal: true
class CommunicationLog < ApplicationRecord
  self.table_name = 'communication_logs'
  belongs_to :lead

  validates :comm_type, inclusion: { in: %w[email sms call note], allow_nil: true }

  scope :for_lead, ->(lead_id) { where(lead_id: lead_id) }
  scope :recent,   -> { order(Arel.sql("COALESCE(sent_at, created_at) DESC")) }
end
