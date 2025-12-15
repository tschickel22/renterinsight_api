# frozen_string_literal: true

module NotifiableContact
  extend ActiveSupport::Concern

  included do
    after_create :notify_assigned_owner, if: -> { owner_id.present? }
    after_update :notify_on_owner_change, if: -> { saved_change_to_owner_id? }
  end

  private

  def notify_assigned_owner
    return unless owner.present? && owner != Current.user

    NotificationService.create(
      recipient: owner,
      notification_type: :contact_assigned,
      notifiable: self,
      actor: Current.user,
      message: "#{Current.user&.name || 'Someone'} assigned contact '#{full_name}' to you",
      deliver_now: true,
      company_id: company_id,
      location_id: location_id
    )
  rescue => e
    Rails.logger.error("Failed to send contact assignment notification: #{e.message}")
  end

  def notify_on_owner_change
    return unless owner.present? && owner != Current.user

    NotificationService.create(
      recipient: owner,
      notification_type: :contact_assigned,
      notifiable: self,
      actor: Current.user,
      message: "#{Current.user&.name || 'Someone'} assigned contact '#{full_name}' to you",
      deliver_now: true,
      company_id: company_id,
      location_id: location_id
    )
  rescue => e
    Rails.logger.error("Failed to send contact reassignment notification: #{e.message}")
  end
end
