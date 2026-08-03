# frozen_string_literal: true

module Ses
  # A verified tenant sending domain, presented in the same shape as the OAuth mailbox
  # connections that CampaignSender already knows how to send through.
  #
  # Quacking like a connection keeps the send path one path. The alternative was branching
  # on "is this SES or a mailbox" at every point that touches a connection (from address,
  # provider, rate-limit key, preflight), which is where divergent behaviour would creep in.
  #
  # Note this is NOT the shared platform SES identity. It is the tenant's own domain, with
  # the tenant's own DKIM. The invariant that campaign mail never falls back to the platform
  # identity still holds.
  class SendingIdentity
    attr_reader :company_domain, :email_address, :display_name

    def initialize(company_domain:, email_address:, display_name: nil)
      @company_domain = company_domain
      @email_address = email_address
      @display_name = display_name.presence
    end

    def provider
      'aws_ses'
    end

    def id
      company_domain.id
    end

    # Rate limits are counted against this key. A verified domain gets its own budget
    # rather than sharing one with the mailbox it replaced, because SES sustains a far
    # higher rate than Exchange Online or Gmail do.
    def connection_key
      "CompanyDomain:#{company_domain.id}"
    end

    def hostname
      company_domain.hostname
    end

    # CampaignSender reads these off whatever it resolves. SES sends are not tied to a
    # user's OAuth credentials, so there is no user to attribute the mailbox to.
    def user_id
      nil
    end

    def user
      nil
    end

    def is_active
      true
    end
    alias is_active? is_active
  end
end
