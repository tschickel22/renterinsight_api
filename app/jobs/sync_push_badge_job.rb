# frozen_string_literal: true

# Corrects the app icon badge on a user's phones after their unread count
# changes. Runs out of band so marking a notification read never waits on
# OneSignal.
class SyncPushBadgeJob < ApplicationJob
  queue_as :default

  retry_on Providers::Push::OneSignalProvider::DeliveryError, wait: 30.seconds, attempts: 2
  discard_on ActiveJob::DeserializationError
  discard_on ActiveRecord::RecordNotFound

  def perform(user_id)
    user = User.find_by(id: user_id)
    return if user.blank?

    PushNotificationService.sync_badge(user)
  end
end
