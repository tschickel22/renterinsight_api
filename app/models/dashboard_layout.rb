# frozen_string_literal: true

class DashboardLayout < ApplicationRecord
  belongs_to :user
  belongs_to :company

  validates :preset_id, presence: true
  validates :layout_data, presence: true

  # Ensure only one layout per user/company/preset combination
  validates :preset_id, uniqueness: { scope: [:user_id, :company_id] }

  # Validate layout_data is valid JSON
  validate :layout_data_is_valid_json

  private

  def layout_data_is_valid_json
    return if layout_data.blank?

    # layout_data should be a hash with required keys
    unless layout_data.is_a?(Hash)
      errors.add(:layout_data, 'must be a valid JSON object')
      return
    end

    required_keys = %w[id presetId cards]
    required_keys.each do |key|
      unless layout_data.key?(key)
        errors.add(:layout_data, "must include '#{key}'")
      end
    end
  end
end
