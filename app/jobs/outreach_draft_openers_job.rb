# frozen_string_literal: true

# Writes the opening message for each contacted lead, for review (backlog E105).
# Nothing is sent from here.
class OutreachDraftOpenersJob < ApplicationJob
  queue_as :default

  def perform(wave_id)
    wave = OutreachWave.find_by(id: wave_id)
    return unless wave&.status == 'drafting' && Outreach::Settings.for(wave.company).add_on?

    wave.contacted.where(status: 'selected').includes(:lead).find_each do |target|
      # Cleared and started over while writing: stop spending on it.
      break unless OutreachWave.exists?(wave.id)

      draft(target)
    end
    wave.update!(status: 'review') if OutreachWave.exists?(wave.id)
  rescue StandardError => e
    Rails.logger.error("[OutreachDraftOpenersJob] wave #{wave_id}: #{e.class}: #{e.message}")
    wave&.update!(status: 'review', build_error: e.message.truncate(240))
  end

  private

  def draft(target)
    Outreach::SiteResearch.for(target)
    result = Outreach::Writer.new(target).opener(target.channel)
    target.update!(status: 'drafted', draft_body: result.body, draft_subject: result.subject,
                   draft_content_item_id: result.content_item&.id, draft_error: result.problem)
  rescue StandardError => e
    Rails.logger.error("[OutreachDraftOpenersJob] target #{target.id}: #{e.class}: #{e.message}")
    target.update!(status: 'drafted', draft_error: 'Could not write this message. Write it here or skip this person.')
  end
end
