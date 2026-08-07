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
    attr_reader :company_domain, :email_address, :display_name, :user_id

    def initialize(company_domain:, email_address:, display_name: nil, user_id: nil)
      @company_domain = company_domain
      @email_address = email_address
      @display_name = display_name.presence
      @user_id = user_id
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

    # Deliberately nil even when user_id is set. CampaignSender passes this straight to
    # CommunicationService, where a non-nil user makes the provider load THAT user's
    # mailbox config (BaseProvider#load_config prefers a user's own email connection).
    # On an SES send that would hand AwsSesProvider an OAuth config with no AWS keys and
    # no region, so the send either fails or silently leaves the verified domain.
    #
    # user_id still carries the person, because CommunicationService stamps it into
    # metadata['sender_user_id'] independently of this. That is what InboundEmail::
    # ReplyNotifier reads to route a reply back to whoever actually sent the mail, so
    # dropping it would push every campaign reply onto the entity owner instead.
    def user
      nil
    end

    def is_active
      true
    end
    alias is_active? is_active
  end
end
