# frozen_string_literal: true

module NotifiableLead
  extend ActiveSupport::Concern

  included do
    after_create :notify_assigned_owner, if: -> { owner_id.present? && !skip_notifications }
    after_update :notify_on_owner_change, if: -> { saved_change_to_owner_id? && !skip_notifications }
    after_update :notify_followers_of_owner_change, if: -> { saved_change_to_owner_id? && !skip_notifications }
    after_update :notify_audience_of_status_change, if: -> { saved_change_to_status? && !skip_notifications }
  end

  private

  def notify_assigned_owner
    return unless owner.present? && owner != Current.user

    NotificationService.create(
      recipient: owner,
      notification_type: :lead_assigned,
      notifiable: self,
      actor: Current.user,
      message: "#{Current.user&.name || 'Someone'} assigned lead '#{full_name}' to you",
      deliver_now: true,
      company_id: company_id,
      location_id: location_id
    )
  rescue => e
    Rails.logger.error("Failed to send lead assignment notification: #{e.message}")
  end

  def notify_on_owner_change
    return unless owner.present? && owner != Current.user

    NotificationService.create(
      recipient: owner,
      notification_type: :lead_assigned,
      notifiable: self,
      actor: Current.user,
      message: "#{Current.user&.name || 'Someone'} assigned lead '#{full_name}' to you",
      deliver_now: true,
      company_id: company_id,
      location_id: location_id
    )
  rescue => e
    Rails.logger.error("Failed to send lead reassignment notification: #{e.message}")
  end

  # The owner and followers hear about every status change (backlog E86),
  # except whoever made it.
  def notify_audience_of_status_change
    label = company&.lead_statuses&.find_by(key: status)&.label || status.to_s.humanize
    notify_audience.each do |u|
      NotificationService.create(
        recipient: u,
        notification_type: :lead_status_changed,
        notifiable: self,
        actor: Current.user,
        message: "#{Current.user&.name || 'Someone'} changed lead '#{full_name}' to #{label}",
        deliver_now: true,
        company_id: company_id,
        location_id: location_id
      )
    end
  rescue => e
    Rails.logger.error("Failed to send lead status notification: #{e.message}")
  end
end
