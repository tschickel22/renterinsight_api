# frozen_string_literal: true

class AccountLink < ApplicationRecord
  belongs_to :company
  belongs_to :linkable, polymorphic: true
  belongs_to :chart_of_account

  PURPOSES = %w[revenue cogs inventory expense receivable payable].freeze

  validates :link_purpose, presence: true, inclusion: { in: PURPOSES }
  validates :chart_of_account_id, presence: true

  scope :active, -> { where(is_active: true) }
  scope :for_purpose, ->(purpose) { where(link_purpose: purpose) }
  scope :by_priority, -> { order(:priority) }
end
