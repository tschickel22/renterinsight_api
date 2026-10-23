# frozen_string_literal: true

module NotifiableDeal
  extend ActiveSupport::Concern

  included do
    after_create :notify_assigned_owner,  if: -> { owner_id.present? && !skip_notifications }
    after_update :notify_on_owner_change, if: -> { saved_change_to_owner_id? && !skip_notifications }
    after_update :notify_followers_of_owner_change, if: -> { saved_change_to_owner_id? && !skip_notifications }
    after_update :notify_audience_of_stage_change, if: -> { saved_change_to_stage? && !skip_notifications }
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

  # The owner and followers hear about every stage move (backlog E86), except
  # whoever made it.
  def notify_audience_of_stage_change
    label = deal_stage_label(stage)
    notify_audience.each do |u|
      NotificationService.create(
        recipient: u,
        notification_type: :deal_stage_changed,
        notifiable: self,
        actor: Current.user,
        message: "#{Current.user&.name || 'Someone'} moved deal '#{name}' to #{label}",
        deliver_now: true,
        company_id: company_id,
        location_id: location_id
      )
    end
  rescue => e
    Rails.logger.error("Failed to send deal stage notification: #{e.message}")
  end

  def deal_stage_label(key)
    stage = Array(company&.pipeline_stages).find { |s| (s['key'] || s[:key]).to_s.casecmp?(key.to_s) }
    (stage && (stage['name'] || stage[:name] || stage['label'] || stage[:label])).presence || key.to_s.humanize
  end
end
