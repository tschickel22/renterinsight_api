# frozen_string_literal: true

class CalculateLeadHealthScoreJob < ApplicationJob
  queue_as :default

  def perform(lead_id)
    lead = Lead.find_by(id: lead_id)
    return unless lead

    LeadHealthScoreService.new(lead).save!
  rescue => e
    Rails.logger.error "[CalculateLeadHealthScoreJob] lead=#{lead_id} failed: #{e.class}: #{e.message}"
    raise
  end
end
