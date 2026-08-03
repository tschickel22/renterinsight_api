# frozen_string_literal: true

module DomainConnect
  # Builds the synchronous apply URL that sends a tenant to their DNS provider to approve
  # our records in one click.
  #
  # Shape defined by the Domain Connect spec:
  #   {urlSyncUX}/v2/domainTemplates/providers/{providerId}/services/{serviceId}/apply
  #     ?domain=<domain>&<template variables>&key=<key host>&sig=<signature>
  #
  # providerId/serviceId identify OUR template, not the DNS provider. urlSyncUX comes from
  # the DNS provider's discovery settings.
  #
  # Signing is not optional in practice: the Domain Connect Templates repo requires
  # syncPubKeyDomain on submitted templates, which means providers verify the signature
  # against a public key we publish in DNS. Without a configured private key this returns
  # nil and the caller falls back to the manual record table.
  class ApplyLink
    # Our identity as a Domain Connect service provider. The template published to the
    # Domain-Connect/Templates repo is named "<provider_id>.<service_id>.json".
    SERVICE_ID = 'email'
    KEY_HOST = '_dck1'

    def self.for(domain:, discovery:, redirect_uri: nil)
      new(domain: domain, discovery: discovery, redirect_uri: redirect_uri).build
    end

    def initialize(domain:, discovery:, redirect_uri: nil)
      @domain = domain
      @discovery = discovery
      @redirect_uri = redirect_uri
    end

    def build
      return nil unless @discovery&.supported?
      return nil if provider_id.blank?
      return nil unless @domain.email_enabled?

      tokens = Array(@domain.ses_dkim_tokens)
      # The template declares exactly three DKIM records. Offering auto-apply with a
      # partial set would write DNS that can never verify.
      return nil unless tokens.length == 3

      query = signed_query
      return nil if query.nil?

      "#{@discovery.url_sync_ux}/v2/domainTemplates/providers/#{provider_id}" \
        "/services/#{SERVICE_ID}/apply?#{query}"
    end

    private

    def provider_id
      @provider_id ||= ENV['DOMAIN_CONNECT_PROVIDER_ID'].presence
    end

    def private_key
      @private_key ||= begin
        pem = ENV['DOMAIN_CONNECT_PRIVATE_KEY'].presence
        pem ? OpenSSL::PKey::RSA.new(pem) : nil
      rescue OpenSSL::PKey::RSAError => e
        Rails.logger.error("[DomainConnect::ApplyLink] invalid private key: #{e.message}")
        nil
      end
    end

    def template_params
      tokens = Array(@domain.ses_dkim_tokens)
      params = {
        'domain' => @domain.hostname,
        'dkim1' => tokens[0],
        'dkim2' => tokens[1],
        'dkim3' => tokens[2],
        'mailfrom' => mail_from_label,
        'sesregion' => ses_region
      }
      params['redirect_uri'] = @redirect_uri if @redirect_uri.present?
      params
    end

    # The template writes MAIL FROM records relative to the domain, so it needs the label
    # ("mail") rather than the fully qualified "mail.example.com".
    def mail_from_label
      from = @domain.ses_mail_from_domain.to_s
      return 'mail' if from.blank?

      from.delete_suffix(".#{@domain.hostname}").presence || 'mail'
    end

    def ses_region
      Ses::Region.current
    end

    # Signature covers the query string exactly as sent, in order, excluding key and sig.
    # Build the string once and reuse it so what we sign and what we send cannot drift.
    def signed_query
      return nil if private_key.nil?

      base = template_params.map { |k, v| "#{k}=#{CGI.escape(v.to_s)}" }.join('&')
      signature = Base64.strict_encode64(private_key.sign(OpenSSL::Digest::SHA256.new, base))

      "#{base}&key=#{KEY_HOST}&sig=#{CGI.escape(signature)}"
    rescue StandardError => e
      Rails.logger.error("[DomainConnect::ApplyLink] signing failed: #{e.message}")
      nil
    end
  end
end
