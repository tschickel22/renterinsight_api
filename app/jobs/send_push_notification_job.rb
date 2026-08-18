# frozen_string_literal: true

# Delivers one staff Notification to OneSignal.
#
# Push is out of band on purpose: a slow or down OneSignal must never hold up
# the request that created the notification, and an in-app notification that
# saved is not undone by a failed push.
class SendPushNotificationJob < ApplicationJob
  queue_as :default

  # A push that arrives long after the event is noise, so this gives up rather
  # than retrying into tomorrow.
  retry_on Providers::Push::OneSignalProvider::DeliveryError, wait: 30.seconds, attempts: 3
  discard_on ActiveJob::DeserializationError
  discard_on ActiveRecord::RecordNotFound

  def perform(notification_id)
    notification = Notification.find_by(id: notification_id)
    return if notification.blank?

    # Someone who already opened the notification in the web app does not need
    # their phone to buzz about it.
    return if notification.read?
    return if notification.push_sent?

    PushNotificationService.deliver_now(notification)
  end
end
