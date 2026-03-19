# frozen_string_literal: true

class OfflineSyncLog < ApplicationRecord
  belongs_to :company
  belongs_to :user

  validates :sync_status, inclusion: { in: %w[pending processing completed failed] }

  scope :recent, -> { order(created_at: :desc).limit(50) }
end
