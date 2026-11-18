# frozen_string_literal: true

module Outreach
  # Passes a conversation to the real sender (backlog E105).
  module Handoff
    module_function

    def perform!(target, reason:, summary: nil)
      conversation = target.conversation
      person = Settings.for(target.company).sender
      conversation.update!(status: 'handed_off', handoff_reason: reason, handed_off_at: Time.current,
                           handed_off_to_user_id: person&.id, assigned_user_id: person&.id || conversation.assigned_user_id)
      target.update!(next_touch_at: nil)
      target.record!('handed_off', metadata: { reason: reason })
      Assistant::Handoff.notify(conversation, person, reason, summary)
    end
  end
end
