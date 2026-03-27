# frozen_string_literal: true

class Lead < ApplicationRecord
  include ActivityTrackable
  include Communicable
  include LocationAware
  include NotifiableLead
  include WebhookNotifiable

  # Transient flag — set to true to suppress assignment notifications (e.g. bulk edits)
  attr_accessor :skip_notifications
  
  belongs_to :company
  belongs_to :location, optional: true
  belongs_to :converted_account, class_name: "Account", optional: true
  belongs_to :source, class_name: "Source", optional: true
  belongs_to :owner, class_name: 'User', foreign_key: 'owner_id', optional: true
  belongs_to :vehicle, optional: true

  # Core CRM associations
  has_many :activities,           dependent: :destroy
  has_many :reminders,            dependent: :destroy
  has_many :lead_activities,      dependent: :destroy
  has_many :lead_scores,          dependent: :destroy
  has_many :ai_insights,          dependent: :destroy
  has_many :nurture_enrollments, as: :enrollable, dependent: :destroy

  has_many :tag_assignments, as: :entity, dependent: :destroy
  has_many :tags, through: :tag_assignments

  # Owner helper methods
  def owner_user
    owner
  end
  
  def owner_user=(user)
    self.owner = user
  end

  # Lifecycle webhook for lead conversion
  after_commit :fire_lifecycle_webhooks, if: :saved_change_to_is_converted?

  # Scopes for filtering converted leads
  scope :active, -> { where(is_converted: [false, nil]) }
  scope :converted, -> { where(is_converted: true) }
  scope :not_converted, -> { where(is_converted: [false, nil]) }

  # Helper method for full name
  def full_name
    if first_name.present? || last_name.present?
      "#{first_name} #{last_name}".strip
    elsif name.present?
      name
    else
      email || "Lead ##{id}"
    end
  end

  # Instance methods for conversion
  def converted?
    is_converted == true
  end

  def can_convert?
    !converted? && email.present?
  end

  private

  # Fire lead.converted lifecycle webhook when is_converted changes to true
  # WebhookNotifiable handles generic lead.created/updated/deleted
  def fire_lifecycle_webhooks
    return unless is_converted == true

    WebhookService.fire(
      company_id: company_id,
      event: 'lead.converted',
      payload: webhook_payload
    )
  rescue => e
    Rails.logger.error "[Lead] Failed to fire lifecycle webhook lead.converted: #{e.message}"
  end

  # ActivityTrackable overrides
  def activity_display_name
    try(:full_name).presence || "#{first_name} #{last_name}".strip.presence || "Lead ##{id}"
  end

  def activity_module_name
    'crm'
  end

  def activity_account_id
    converted_account_id
  end
end
