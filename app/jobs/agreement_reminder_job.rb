class AgreementReminderJob < ApplicationJob
  queue_as :default

  def perform
    AgreementReminderService.check_and_send_reminders
  end
end
