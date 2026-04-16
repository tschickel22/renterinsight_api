# frozen_string_literal: true

class ExportJob < ApplicationRecord
  belongs_to :company
  belongs_to :user

  STATUSES = %w[pending processing completed failed].freeze
  FORMATS  = %w[csv xlsx json].freeze

  validates :module_type, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :format, inclusion: { in: FORMATS }

  scope :recent, -> { order(created_at: :desc) }
end
