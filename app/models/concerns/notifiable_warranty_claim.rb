# frozen_string_literal: true

module NotifiableWarrantyClaim
  extend ActiveSupport::Concern

  included do
    after_create :notify_assigned_owner,   if: -> { owner_id.present? && !skip_notifications }
    after_update :notify_on_owner_change,  if: -> { saved_change_to_owner_id? && !skip_notifications }
    after_update :notify_on_status_change, if: -> { saved_change_to_status? && !skip_notifications }
  end

  private

  def notify_assigned_owner
    return unless owner.present? && owner != Current.user

    NotificationService.create(
      recipient: owner,
      notification_type: :warranty_claim_assigned,
      notifiable: self,
      actor: Current.user,
      message: "Warranty claim #{claim_number} for service ticket ##{service_ticket_id} has been assigned to you",
      deliver_now: true,
      company_id: company_id,
      location_id: location_id
    )
  rescue => e
    Rails.logger.error("Failed to send warranty claim assignment notification: #{e.message}")
  end

  def notify_on_owner_change
    return unless owner.present? && owner != Current.user

    NotificationService.create(
      recipient: owner,
      notification_type: :warranty_claim_assigned,
      notifiable: self,
      actor: Current.user,
      message: "#{Current.user&.name || 'Someone'} assigned warranty claim #{claim_number} to you",
      deliver_now: true,
      company_id: company_id,
      location_id: location_id
    )
  rescue => e
    Rails.logger.error("Failed to send warranty claim reassignment notification: #{e.message}")
  end

  def notify_on_status_change
    return unless owner.present? && owner != Current.user
    
    # Map status to user-friendly message
    status_message = case status
    when 'submitted'
      "Warranty claim #{claim_number} has been submitted to manufacturer"
    when 'under_review'
      "Warranty claim #{claim_number} is now under review by manufacturer"
    when 'approved'
      "Warranty claim #{claim_number} has been approved! Amount: $#{approved_amount&.round(2)}"
    when 'denied'
      "Warranty claim #{claim_number} was denied by manufacturer"
    when 'short_paid'
      "Warranty claim #{claim_number} was short-paid. Approved: $#{approved_amount&.round(2)}"
    when 'closed'
      "Warranty claim #{claim_number} has been closed"
    else
      "Warranty claim #{claim_number} status changed to #{status}"
    end

    # Determine priority based on status
    priority = case status
    when 'approved'
      'high'
    when 'denied'
      'normal'
    else
      'normal'
    end

    NotificationService.create(
      recipient: owner,
      notification_type: :warranty_claim_status_changed,
      notifiable: self,
      actor: Current.user,
      message: status_message,
      deliver_now: true,
      company_id: company_id,
      location_id: location_id,
      priority: priority
    )
  rescue => e
    Rails.logger.error("Failed to send warranty claim status change notification: #{e.message}")
  end
end
