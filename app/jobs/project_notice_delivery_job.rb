# frozen_string_literal: true

# Emails and texts one project notice (E87) as its recipient's Notification
# Center switches allow. The bell already shows it; this is the part that
# reaches someone who isn't looking at the app.
class ProjectNoticeDeliveryJob < ApplicationJob
  queue_as :default

  # Enqueued inside the transaction that made the notice; give the commit a moment.
  retry_on ActiveRecord::RecordNotFound, wait: 5.seconds, attempts: 3

  def perform(notification_id)
    NotificationService.deliver(Notification.find(notification_id))
  end
end
