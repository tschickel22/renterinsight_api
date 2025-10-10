# frozen_string_literal: true

class UserNotificationsChannel < ApplicationCable::Channel
  def subscribed
    user_id = params[:user_id] || current_user&.id
    
    if user_id
      stream_from "user_notifications_#{user_id}"
      # Also subscribe to lead notifications for this user
      stream_from "lead_notifications_#{user_id}"
      Rails.logger.info "[UserNotificationsChannel] User #{user_id} subscribed to notifications"
    else
      reject
    end
  end

  def unsubscribed
    Rails.logger.info "[UserNotificationsChannel] User unsubscribed from notifications"
  end
end
