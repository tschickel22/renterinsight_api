class LeadNotificationChannel < ApplicationCable::Channel
  def subscribed
    if params[:user_id].present?
      stream_from "lead_notifications_#{params[:user_id]}"
      Rails.logger.info "[LeadNotificationChannel] User #{params[:user_id]} subscribed to lead notifications"
    end
  end

  def unsubscribed
    Rails.logger.info "[LeadNotificationChannel] User unsubscribed from lead notifications"
  end
end
