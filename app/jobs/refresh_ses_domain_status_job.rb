# frozen_string_literal: true

# Sweeps sending domains awaiting SES verification so a tenant who publishes their DNS
# records overnight finds the domain already verified, rather than having to come back and
# press a button.
#
# DKIM verification normally completes within minutes but AWS allows up to 72 hours, so the
# sweep keeps trying for a while before giving up on a domain.
class RefreshSesDomainStatusJob < ApplicationJob
  queue_as :default

  GIVE_UP_AFTER = 7.days
  MIN_RECHECK_INTERVAL = 10.minutes

  def perform(domain_id = nil)
    return refresh_one(CompanyDomain.find_by(id: domain_id)) if domain_id.present?

    due_domains.find_each { |domain| refresh_one(domain) }
  end

  private

  def due_domains
    CompanyDomain
      .email_pending
      .where(created_at: GIVE_UP_AFTER.ago..)
      .where('ses_checked_at IS NULL OR ses_checked_at < ?', MIN_RECHECK_INTERVAL.ago)
  end

  def refresh_one(domain)
    return if domain.nil?

    was_verified = domain.email_verified?
    Ses::IdentityManager.new(domain).refresh_status!

    return unless domain.reload.email_verified? && !was_verified

    Rails.logger.info("[RefreshSesDomainStatus] #{domain.hostname} verified for company #{domain.company_id}")
  rescue Ses::IdentityManager::SesError => e
    # Already recorded on the domain as ses_error. One unreachable domain should not stop
    # the sweep for the rest.
    Rails.logger.warn("[RefreshSesDomainStatus] #{domain.hostname}: #{e.message}")
  end
end
