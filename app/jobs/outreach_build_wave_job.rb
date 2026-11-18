# frozen_string_literal: true

# Builds a Proactive Outreach wave's audience (backlog E105).
class OutreachBuildWaveJob < ApplicationJob
  queue_as :default

  def perform(wave_id, user_id = nil)
    wave = OutreachWave.find_by(id: wave_id)
    return unless wave&.status == 'building' && Outreach::Settings.for(wave.company).add_on?

    Outreach::AudienceBuilder.new(wave, user: wave.company.users.find_by(id: user_id)).call
  rescue StandardError => e
    Rails.logger.error("[OutreachBuildWaveJob] wave #{wave_id}: #{e.class}: #{e.message}")
    wave&.update!(status: 'failed', build_error: e.message.truncate(240))
  end
end
