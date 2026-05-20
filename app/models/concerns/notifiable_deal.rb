# frozen_string_literal: true

module NotifiableDeal
  extend ActiveSupport::Concern

  included do
    after_create :notify_assigned_owner,  if: -> { owner_id.present? && !skip_notifications }
    after_update :notify_on_owner_change, if: -> { saved_change_to_owner_id? && !skip_notifications }
  end

  private

  def notify_assigned_owner
    return unless owner.present? && owner != Current.user

    NotificationService.create(
      recipient: owner,
      notification_type: :deal_assigned,
      notifiable: self,
      actor: Current.user,
      message: "#{Current.user&.name || 'Someone'} assigned deal '#{name}' to you",
      deliver_now: true,
      company_id: company_id,
      location_id: location_id
    )
  rescue => e
    Rails.logger.error("Failed to send deal assignment notification: #{e.message}")
  end

  def notify_on_owner_change
    return unless owner.present? && owner != Current.user

    NotificationService.create(
      recipient: owner,
      notification_type: :deal_assigned,
      notifiable: self,
      actor: Current.user,
      message: "#{Current.user&.name || 'Someone'} assigned deal '#{name}' to you",
      deliver_now: true,
      company_id: company_id,
      location_id: location_id
    )
  rescue => e
    Rails.logger.error("Failed to send deal reassignment notification: #{e.message}")
  end
end
