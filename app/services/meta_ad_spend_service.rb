# frozen_string_literal: true

# Pulls Meta Marketing API campaign + insights data and upserts into the
# local ad_campaigns table. Idempotent — safe to re-run.
class MetaAdSpendService
  class << self
    def sync_for_company(company)
      integration = FacebookIntegration.current_for(company)
      return { synced: 0, skipped: 'no_integration' } unless integration

      metadata = integration.metadata.to_h.deep_stringify_keys
      ad_account_id = metadata['ad_account_id']
      return { synced: 0, skipped: 'no_ad_account' } if ad_account_id.blank?

      # Insights on an ad account need a user token with ads_read; a Page token
      # can't read /act_*. Fall back to the Page token for legacy connections.
      token = integration.user_access_token.presence || integration.page_access_token

      begin
        response = MetaGraphApi.get_ad_campaigns(ad_account_id, token)
      rescue MetaGraphApi::ExpiredTokenError => e
        integration.update(status: 'expired')
        Rails.logger.warn "[MetaAdSpendService] company=#{company.id} expired: #{e.message}"
        return { synced: 0, skipped: 'expired_token' }
      rescue MetaGraphApi::Error => e
        Rails.logger.error "[MetaAdSpendService] company=#{company.id} api error: #{e.message}"
        return { synced: 0, skipped: 'api_error', error: e.message }
      end

      campaigns = Array(response['data'])
      synced = 0

      campaigns.each do |raw|
        record = company.ad_campaigns.find_or_initialize_by(external_campaign_id: raw['id'])

        insights = raw.dig('insights', 'data', 0) || {}

        record.assign_attributes(
          name:            raw['name'],
          objective:       raw['objective'],
          status:          raw['status'],
          daily_budget:    cents_to_dollars(raw['daily_budget']),
          lifetime_budget: cents_to_dollars(raw['lifetime_budget']),
          spend:           insights['spend'].to_f,
          impressions:     insights['impressions'].to_i,
          clicks:          insights['clicks'].to_i,
          reach:           insights['reach'].to_i,
          # Stamp the source account so switching accounts switches the list
          # instead of stacking the new account's campaigns on the old ones.
          ad_account_id:   ad_account_id,
          # Bounds lead attribution — a stopped campaign shouldn't keep
          # claiming leads that arrive months later.
          started_at:      parse_time(raw['start_time']),
          stopped_at:      parse_time(raw['stop_time']),
          is_deleted:      false,
          synced_at:       Time.current
        )
        record.save!
        synced += 1
      end

      { synced: synced, ad_account_id: ad_account_id }
    end

    private

    def parse_time(value)
      return nil if value.blank?

      Time.zone.parse(value.to_s)
    rescue ArgumentError
      nil
    end

    def cents_to_dollars(value)
      return nil if value.nil?
      value.to_f / 100.0
    end
  end
end
