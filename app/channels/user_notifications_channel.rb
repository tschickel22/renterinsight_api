# frozen_string_literal: true

# The signed-in person's own pop-ups: reminders, notifications and new leads.
# Only ever their own; a user_id the browser sends is ignored.
class UserNotificationsChannel < ApplicationCable::Channel
  def subscribed
    stream_from "user_notifications_#{current_user.id}"
    stream_from "lead_notifications_#{current_user.id}"
  end
end
