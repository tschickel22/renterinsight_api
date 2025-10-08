# frozen_string_literal: true

class Company < ApplicationRecord
  has_many :accounts, dependent: :destroy
  
  # Use the polymorphic settings table for storing company-specific settings
  def communications_settings
    setting = Setting.find_by(scope_type: 'Company', scope_id: id, key: 'communications')
    setting ? JSON.parse(setting.value) : nil
  rescue JSON::ParserError
    nil
  end
  
  def communications_settings=(value)
    setting = Setting.find_or_initialize_by(
      scope_type: 'Company',
      scope_id: id,
      key: 'communications'
    )
    setting.value = value.to_json
    setting.save!
  end
end
