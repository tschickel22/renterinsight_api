# frozen_string_literal: true

# Thirty minutes after a visit started and nobody has marked it, ask the rep
# whether the buyer came (E96 phase 2). Marking it No show is what lets Quinn
# AI text the buyer two new times and keep following up, so a missed visit is
# not left sitting as "pending".
#
# Only where Quinn AI could act on it: the dealer has Quinn by text, or Quinn
# booked the visit. Asked once per visit (metadata check_in_asked_at).
class VisitCheckInJob < ApplicationJob
  queue_as :low

  AFTER = 30.minutes
  # Visits older than this are left alone (the first run after release would
  # otherwise ask about every old pending visit).
  WINDOW = 6.hours
  MODELS = { 'LeadActivity' => :lead, 'ContactActivity' => :contact }.freeze

  def perform
    MODELS.each_key do |name|
      model = name.constantize
      model.where(activity_type: 'meeting', status: 'pending')
           .where(start_time: WINDOW.ago..AFTER.ago)
           .where("(metadata->>'check_in_asked_at') IS NULL")
           .find_each { |visit| ask(visit) }
    end
  end

  def ask(visit)
    record = visit.public_send(MODELS[visit.class.name])
    return mark(visit) unless record
    company = record.company
    settings = Assistant::Settings.for(company)
    by_quinn = visit.metadata.is_a?(Hash) && visit.metadata['booked_by'] == 'quinn_ai'
    return unless settings.enabled? || by_quinn

    mark(visit)
    user = visit.assigned_to || visit.user
    return unless user&.active?

    who = Assistant::Learn.display_name(record, fallback: 'the buyer')
    at = Appointments::TimeText.for(visit, company).split(' at ').last
    quinn = record.is_a?(Lead) && settings.enabled? ? " If not, mark it No show and #{settings.assistant_name} AI will text them new times." : ' If not, mark it No show.'
    path = record.is_a?(Lead) ? "/crm/leads/#{record.id}?tab=activities" : "/contacts/#{record.id}?tab=activities"
    NotificationService.create(
      recipient: user, notification_type: :visit_check_in, notifiable: record, company_id: company.id,
      message: "Did #{who} make the #{at} visit?#{quinn}", action_url: path, action_text: 'Mark the visit',
      location_id: record.try(:location_id), metadata: { activity_type: visit.class.name, activity_id: visit.id }
    )
  rescue StandardError => e
    Rails.logger.error("[VisitCheckInJob] #{visit.class.name} #{visit.id}: #{e.class}: #{e.message}")
  end

  private

  def mark(visit)
    meta = (visit.metadata.is_a?(Hash) ? visit.metadata : {}).merge('check_in_asked_at' => Time.current.iso8601)
    visit.update_columns(metadata: meta.deep_stringify_keys)
  end
end
