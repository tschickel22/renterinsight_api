# frozen_string_literal: true

# Daily job that refreshes Facebook long-lived tokens before expiry.
# Finds active FacebookIntegration rows with token_expires_at < 7 days out
# and exchanges them for a fresh long-lived token.
class FacebookTokenRefreshJob < ApplicationJob
  queue_as :low

  REFRESH_THRESHOLD = 7.days

  def perform
    refreshed = 0
    failed    = 0
    expired   = 0

    integrations = FacebookIntegration.active
                    .where('token_expires_at IS NULL OR token_expires_at < ?', REFRESH_THRESHOLD.from_now)

    integrations.find_each do |integration|
      source_token = integration.user_access_token.presence || integration.page_access_token
      if source_token.blank?
        Rails.logger.warn "[FacebookTokenRefreshJob] integration=#{integration.id} has no token to refresh"
        next
      end

      begin
        resp = MetaGraphApi.exchange_token(source_token)
      rescue MetaGraphApi::ExpiredTokenError => e
        Rails.logger.warn "[FacebookTokenRefreshJob] integration=#{integration.id} token already expired: #{e.message}"
        integration.update(status: 'expired')
        expired += 1
        next
      rescue MetaGraphApi::Error => e
        Rails.logger.error "[FacebookTokenRefreshJob] integration=#{integration.id} refresh failed: #{e.message}"
        failed += 1
        next
      end

      integration.update!(
        user_access_token: resp['access_token'],
        token_expires_at:  Time.current + resp['expires_in'].to_i.seconds,
        status:            'active'
      )
      refreshed += 1
    end

    Rails.logger.info "[FacebookTokenRefreshJob] refreshed=#{refreshed} expired=#{expired} failed=#{failed}"
  end
end
