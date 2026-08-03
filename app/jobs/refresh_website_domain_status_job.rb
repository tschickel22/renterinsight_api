# frozen_string_literal: true

# Keeps custom hostname status in step with Cloudflare.
#
# Certificate issuance happens on Cloudflare's schedule, minutes to hours after DNS is
# correct. Nothing here noticed. Status changed only when somebody pressed Verify, so a
# dealer's site could be live and serving while the screen said pending indefinitely, and a
# dealer has no reason to know that pressing a button is what fixes it.
#
# Mirrors RefreshSesDomainStatusJob, which does the same for sending domains.
class RefreshWebsiteDomainStatusJob < ApplicationJob
  queue_as :default

  GIVE_UP_AFTER = 7.days
  MIN_RECHECK_INTERVAL = 10.minutes

  def perform(domain_id = nil)
    return refresh_one(CompanyDomain.find_by(id: domain_id)) if domain_id.present?

    due_domains.find_each { |domain| refresh_one(domain) }
  end

  private

  # Only domains still waiting on something. A domain that is verified with an active
  # certificate is finished, and re-polling it would spend an API call per domain per sweep
  # forever.
  def due_domains
    CompanyDomain
      .where(web_enabled: true)
      .where.not(cloudflare_custom_hostname_id: [nil, ''])
      .where("verification_status IS DISTINCT FROM 'active' OR ssl_status IS DISTINCT FROM 'active'")
      .where(created_at: GIVE_UP_AFTER.ago..)
      .where('dns_checked_at IS NULL OR dns_checked_at < ?', MIN_RECHECK_INTERVAL.ago)
  end

  def refresh_one(domain)
    return if domain.nil?

    was_ready = domain.ready_for_use?
    result = Websites::CloudflareStatusRefresher.call(domain)

    return unless result.ready? && !was_ready

    Rails.logger.info(
      "[RefreshWebsiteDomainStatus] #{domain.hostname} is live for company #{domain.company_id}"
    )
  rescue StandardError => e
    # One unreachable domain must not stop the sweep for the rest.
    Rails.logger.warn("[RefreshWebsiteDomainStatus] #{domain&.hostname}: #{e.class}: #{e.message}")
  end
end
