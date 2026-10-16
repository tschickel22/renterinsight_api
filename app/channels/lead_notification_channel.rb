# frozen_string_literal: true

# New lead pop-ups for the signed-in person (also part of
# UserNotificationsChannel). A user_id the browser sends is ignored.
class LeadNotificationChannel < ApplicationCable::Channel
  def subscribed
    stream_from "lead_notifications_#{current_user.id}"
  end
end
