# frozen_string_literal: true

class ProjectNotificationPreference < ApplicationRecord
  belongs_to :project
  belongs_to :company
  belongs_to :recipient, polymorphic: true

  validates :recipient_type, inclusion: { in: %w[User Contact] }

  scope :active, -> { where(is_active: true) }
  scope :for_event, ->(event) { where("notify_#{event}" => true) }
  scope :via_email, -> { where(via_email: true) }
  scope :via_sms, -> { where(via_sms: true) }

  def effective_email
    recipient_email.presence || recipient.try(:email)
  end

  def effective_phone
    recipient_phone.presence || recipient.try(:phone) || recipient.try(:mobile_phone)
  end
end
