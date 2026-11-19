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
      scan_task!(target, person, summary) if reason.to_s == 'wants_site_scan'
      Assistant::Handoff.notify(conversation, person, reason, summary)
    end

    # They asked for the full website report or to see their site with
    # TrueBuild. Tom runs the full scan and picks the preview himself.
    def scan_task!(target, person, summary)
      target.record!('scan_requested')
      return unless person

      site = target.site_research.to_h['url']
      target.lead.lead_activities.create!(
        user: person, assigned_to: person, activity_type: 'task', status: 'pending', priority: 'high',
        subject: "Run a full site scan for #{target.lead.company_name.presence || Assistant::Learn.display_name(target.lead)} and pick a TrueBuild preview",
        description: ["They asked for the full website report or a preview of their site with TrueBuild.", ("Site: #{site}" if site),
                      ("Where it stands: #{summary}" if summary.present?)].compact.join("\n"),
        due_date: 1.day.from_now.change(hour: 17)
      )
    rescue StandardError => e
      Rails.logger.error("[Outreach::Handoff] scan task not created for target #{target.id}: #{e.class}: #{e.message}")
    end
  end
end
