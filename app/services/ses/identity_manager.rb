# frozen_string_literal: true

require 'aws-sdk-sesv2'

module Ses
  # Creates and tracks a per-tenant SES sending identity for a CompanyDomain.
  #
  # A tenant that verifies their own domain sends as themselves with their own DKIM, which
  # is the whole point: their campaign reputation stays theirs, and a burst can no longer
  # get their real business mailbox blocked the way Microsoft blocked ours on 2026-07-31.
  #
  # Nothing here ever falls back to the shared platform identity. If a tenant has no
  # verified domain, campaign resolution keeps using their OAuth mailbox.
  class IdentityManager
    class SesError < StandardError; end

    # SES sends bounces for the MAIL FROM domain, and using a subdomain we control the SPF
    # for is what makes SPF align with the From header rather than defaulting to
    # amazonses.com.
    #
    # Deliberately NOT "mail". AWS docs use mail.<domain> in examples, but that subdomain is
    # already taken on real domains far too often: our own mail.dealertide.com carries the
    # inbound campaign reply MX, and dealers commonly point mail.<domain> at webmail. A
    # MAIL FROM MX published there would silently replace the record that receives their
    # mail. "bounce" describes what the subdomain is actually for and collides with almost
    # nothing.
    DEFAULT_MAIL_FROM_PREFIX = 'bounce'

    def self.mail_from_prefix
      ENV['SES_MAIL_FROM_PREFIX'].presence || DEFAULT_MAIL_FROM_PREFIX
    end

    def initialize(domain, client: nil)
      @domain = domain
      @client = client
    end

    # Registers the domain with SES and stores the DKIM records the tenant has to publish.
    # Safe to call again: SES returns the existing identity's tokens rather than rotating
    # them, so a retry does not invalidate records a tenant has already published.
    def create_identity!
      response = client.create_email_identity(
        email_identity: domain.hostname,
        dkim_signing_attributes: { next_signing_key_length: 'RSA_2048_BIT' }
      )
      tokens = Array(response.dkim_attributes&.tokens)
      mail_from_applied = apply_mail_from!
      persist_identity(tokens: tokens, status: response.dkim_attributes&.status,
                       mail_from_applied: mail_from_applied)
      domain
    rescue Aws::SESV2::Errors::AlreadyExistsException
      # Identity already registered — by an earlier attempt, or by another environment
      # sharing this AWS account, since SES identities are account-level rather than
      # per-environment. Adopt it.
      #
      # refresh_status! deliberately does not touch email_enabled, because disabling is an
      # explicit separate action and a status poll must never silently re-enable a domain a
      # tenant turned off. Enabling is this method's job, so it is done here. Without this
      # the domain verifies in SES and records email_verified_at while email_enabled stays
      # false, and email_verified? requires both — so a fully working domain reads as
      # pending forever.
      refresh_status!
      domain.update!(email_enabled: true) unless domain.email_enabled?
      domain
    rescue Aws::SESV2::Errors::ServiceError => e
      record_error(e)
      raise SesError, "Could not create SES identity for #{domain.hostname}: #{e.message}"
    end

    # Re-reads SES for the current DKIM and MAIL FROM state and flips email_verified_at
    # once SES itself reports success. Verification is never inferred from our own DNS
    # lookups: SES is the only authority on whether it will sign for this domain.
    def refresh_status!
      response = client.get_email_identity(email_identity: domain.hostname)

      dkim = response.dkim_attributes
      verified = dkim&.status == 'SUCCESS'

      domain.update!(
        ses_identity_status: dkim&.status,
        ses_dkim_tokens: Array(dkim&.tokens).presence || domain.ses_dkim_tokens,
        ses_mail_from_domain: response.mail_from_attributes&.mail_from_domain,
        ses_mail_from_status: response.mail_from_attributes&.mail_from_domain_status,
        email_verified_at: verified ? (domain.email_verified_at || Time.current) : nil,
        ses_checked_at: Time.current,
        ses_error: nil
      )
      domain
    rescue Aws::SESV2::Errors::NotFoundException
      domain.update!(
        ses_identity_status: 'NOT_FOUND',
        email_verified_at: nil,
        ses_checked_at: Time.current,
        ses_error: 'Identity no longer exists in SES'
      )
      domain
    rescue Aws::SESV2::Errors::ServiceError => e
      record_error(e)
      raise SesError, "Could not read SES identity for #{domain.hostname}: #{e.message}"
    end

    def delete_identity!
      client.delete_email_identity(email_identity: domain.hostname)
      true
    rescue Aws::SESV2::Errors::NotFoundException
      true
    rescue Aws::SESV2::Errors::ServiceError => e
      Rails.logger.warn("[Ses::IdentityManager] delete failed for #{domain.hostname}: #{e.message}")
      false
    end

    def self.client
      Aws::SESV2::Client.new(
        access_key_id: ENV['AWS_ACCESS_KEY_ID'],
        secret_access_key: ENV['AWS_SECRET_ACCESS_KEY'],
        region: Ses::Region.current
      )
    end

    private

    attr_reader :domain

    def client
      @client ||= self.class.client
    end

    def apply_mail_from!
      # Never claim a subdomain that already receives mail. Publishing our MAIL FROM MX
      # over an existing one would silently break whatever was using it, and a tenant
      # following our instructions has no way to know that is what they are doing.
      if subdomain_already_receives_mail?
        Rails.logger.warn(
          "[Ses::IdentityManager] #{mail_from_domain} already has MX records; skipping custom " \
          'MAIL FROM. Bounces route via amazonses.com and SPF alignment is weaker, but no ' \
          'existing mail is broken.'
        )
        return false
      end

      client.put_email_identity_mail_from_attributes(
        email_identity: domain.hostname,
        mail_from_domain: mail_from_domain,
        # Reject rather than fall back to amazonses.com. A silent fallback would break the
        # SPF alignment the custom MAIL FROM exists to provide, without telling anyone.
        behavior_on_mx_failure: 'REJECT_MESSAGE'
      )
      true
    rescue Aws::SESV2::Errors::ServiceError => e
      # A missing MAIL FROM weakens alignment but does not stop DKIM verification, so this
      # is logged rather than fatal. DKIM alone still lets the domain send.
      Rails.logger.warn("[Ses::IdentityManager] MAIL FROM setup failed for #{domain.hostname}: #{e.message}")
      false
    end

    def subdomain_already_receives_mail?
      require 'resolv'
      Resolv::DNS.open(timeouts: 3) do |dns|
        dns.getresources(mail_from_domain, Resolv::DNS::Resource::IN::MX).any?
      end
    rescue StandardError => e
      # An unresolvable lookup must not read as "safe to overwrite". Treat it as occupied
      # so the worst case is a weaker MAIL FROM, never a broken inbound mail flow.
      Rails.logger.warn("[Ses::IdentityManager] MX check failed for #{mail_from_domain}: #{e.message}")
      true
    end

    def mail_from_domain
      "#{self.class.mail_from_prefix}.#{domain.hostname}"
    end

    # ses_mail_from_domain is only recorded when SES actually accepted it, because the DNS
    # record list shown to the tenant is derived from it. Advertising records for a MAIL
    # FROM we declined to configure would ask them to publish an MX that does nothing, and
    # in the collision case would ask them to break their own inbound mail.
    def persist_identity(tokens:, status:, mail_from_applied: true)
      domain.update!(
        email_enabled: true,
        ses_identity_status: status || 'PENDING',
        ses_dkim_tokens: tokens,
        ses_mail_from_domain: mail_from_applied ? mail_from_domain : nil,
        ses_mail_from_status: mail_from_applied ? 'PENDING' : nil,
        email_verified_at: nil,
        ses_checked_at: Time.current,
        ses_error: nil
      )
    end

    def record_error(error)
      domain.update_columns(
        ses_error: error.message.to_s[0, 500],
        ses_checked_at: Time.current
      )
    rescue StandardError
      nil
    end
  end
end
