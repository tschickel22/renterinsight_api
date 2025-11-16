# frozen_string_literal: true

class LocationActivity < ApplicationRecord
  belongs_to :location
  belongs_to :user, optional: true

  VALID_CATEGORIES = %w[branding communication operational user_assignment settings].freeze
  VALID_ACTIONS = %w[
    created updated deleted
    branding_changed communication_changed operational_changed
    user_assigned user_removed user_updated
    settings_cleared settings_overridden
  ].freeze

  validates :action, presence: true, inclusion: { in: VALID_ACTIONS }
  validates :category, presence: true, inclusion: { in: VALID_CATEGORIES }
  validates :occurred_at, presence: true

  scope :recent, -> { order(occurred_at: :desc) }
  scope :by_category, ->(category) { where(category: category) }
  scope :by_action, ->(action) { where(action: action) }
  scope :for_location, ->(location_id) { where(location_id: location_id) }

  # Create activity for settings changes
  def self.log_settings_change(location:, category:, user:, changes:)
    create!(
      location: location,
      user: user,
      action: "#{category}_changed",
      category: category,
      description: generate_description(category, changes),
      metadata: { changes: changes },
      occurred_at: Time.current
    )
  end

  # Create activity for settings cleared
  def self.log_settings_cleared(location:, category:, user:)
    create!(
      location: location,
      user: user,
      action: 'settings_cleared',
      category: category,
      description: "#{category.humanize} settings cleared - will inherit from company or platform",
      metadata: { cleared: true },
      occurred_at: Time.current
    )
  end

  # Create activity for user assignment
  def self.log_user_assignment(location:, user:, assigned_user:, role:)
    create!(
      location: location,
      user: user,
      action: 'user_assigned',
      category: 'user_assignment',
      description: "#{assigned_user.name || assigned_user.email} assigned as #{role&.humanize || 'staff'}",
      metadata: { assigned_user_id: assigned_user.id, role: role },
      occurred_at: Time.current
    )
  end

  private

  def self.generate_description(category, changes)
    case category
    when 'branding'
      fields = changes.keys.map { |k| k.humanize.downcase }.to_sentence
      "Branding updated: #{fields}"
    when 'communication'
      fields = changes.keys.map { |k| k.humanize.downcase }.to_sentence
      "Communication settings updated: #{fields}"
    when 'operational'
      fields = changes.keys.map { |k| k.humanize.downcase }.to_sentence
      "Operational settings updated: #{fields}"
    else
      "#{category.humanize} settings updated"
    end
  end
end
