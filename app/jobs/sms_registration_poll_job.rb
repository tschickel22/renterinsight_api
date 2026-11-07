# frozen_string_literal: true

# Every 30 minutes: dealers' texting registrations under carrier review (E96).
class SmsRegistrationPollJob < ApplicationJob
  queue_as :default

  def perform
    SmsRegistration::StatusPoller.run
  end
end
