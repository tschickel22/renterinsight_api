# frozen_string_literal: true

# Sends Quinn AI's follow-ups that are due (E96, Assistant::FollowUp). Every
# 15 minutes; quiet hours and the stop rules are checked per conversation.
class AssistantFollowUpJob < ApplicationJob
  queue_as :low

  def perform
    Assistant::FollowUp.run_due
  end
end
