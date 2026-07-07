# frozen_string_literal: true
class TagAssignment < ApplicationRecord
  self.table_name = 'tag_assignments'

  belongs_to :company, optional: true
  belongs_to :tag
  belongs_to :entity, polymorphic: true, optional: true

  scope :for_entity, ->(etype, eid) { where(entity_type: etype, entity_id: eid) }
  scope :for_company, ->(company_id) { where(company_id: [company_id, nil]) }

  # Newly tagging an entity may make it match a dynamic-audience campaign
  # that's already running (e.g. a weekly newsletter for contacts tagged
  # "weekly-favorites"). Without this, the newly-tagged entity wouldn't
  # get enrolled until CampaignSchedulerJob's next tick and only if that
  # campaign happens to re-enroll — leaving up to a full cycle of latency.
  # Enqueues the enroller for each matching dynamic campaign so the new
  # tag propagates immediately. AudienceEnroller is idempotent (skips
  # already-enrolled recipients), so re-runs are safe.
  after_commit :refresh_dynamic_campaigns, on: %i[create]

  private

  def refresh_dynamic_campaigns
    return if entity_type.blank? || entity_id.blank?
    scope_company_id = company_id || entity&.try(:company_id)
    return if scope_company_id.blank?

    # Match campaigns whose primary source_type OR any additional_source_types
    # entry equals the tagged entity_type — that way a Lead+Contact newsletter
    # (source_type=Contact, additional=['Lead']) refreshes on Lead tags too.
    Campaign
      .where(company_id: scope_company_id, audience_mode: 'dynamic', status: %w[running scheduled])
      .joins(:campaign_audience)
      .where(
        "campaign_audiences.source_type = ? OR campaign_audiences.additional_source_types @> ?::jsonb",
        entity_type,
        [entity_type].to_json
      )
      .find_each do |campaign|
        # Simple in-process dedupe so a bulk tag operation doesn't
        # thunder the queue with N identical enroller jobs.
        cache_key = "campaigns:dynamic_refresh:#{campaign.id}"
        next unless Rails.cache.write(cache_key, true, expires_in: 15.seconds, unless_exist: true)
        CampaignAudienceEnrollerJob.perform_later(campaign.id)
      end
  rescue StandardError => e
    Rails.logger.warn "[TagAssignment#refresh_dynamic_campaigns] #{e.class}: #{e.message}"
  end
end
