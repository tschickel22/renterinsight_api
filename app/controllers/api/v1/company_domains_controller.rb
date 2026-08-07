# API controller for managing custom domains via Cloudflare for SaaS
class Api::V1::CompanyDomainsController < ApplicationController
  SENDING_DOMAIN_MODULE = 'marketing.sending_domain'

  before_action :set_company_scope
  before_action :set_domain, only: [:show, :update, :destroy, :verify, :check_dns, :activate, :deactivate,
                                    :enable_email, :check_email, :disable_email, :domain_connect]
  
  # GET /api/v1/company_domains
  def index
    return unless authorize_action!('company_settings', 'read')
    
    domains = @company.company_domains
                      .order(created_at: :desc)
                      .includes(:website)
    
    render json: {
      domains: domains.map { |domain| domain_json(domain) },
      cloudflare_enabled: cloudflare_enabled?,
      # A domain has to be told which site it serves. Without this the picker has nothing to
      # offer and every domain arrives unlinked, serving the platform root instead of the
      # dealer's site.
      available_websites: assignable_websites
    }
  end
  
  # GET /api/v1/company_domains/:id
  def show
    return unless authorize_action!('company_settings', 'read')
    
    render json: { domain: domain_json(@domain) }
  end
  
  # POST /api/v1/company_domains
  #
  # purpose: 'web' (default), 'email', or 'both'. An email-only domain needs no Cloudflare
  # custom hostname, so requiring Cloudflare for every domain would block sending setup on
  # an installation that only ever wanted to send mail.
  def create
    return unless authorize_action!('company_settings', 'update')

    purpose = params[:purpose].presence || 'web'
    unless %w[web email both].include?(purpose)
      return render json: { error: "Unknown purpose #{purpose}" }, status: :unprocessable_entity
    end

    wants_web = %w[web both].include?(purpose)

    if wants_web && !cloudflare_enabled?
      return render json: {
        error: 'Cloudflare for SaaS is not enabled for this installation'
      }, status: :forbidden
    end

    hostname = params[:hostname]&.strip

    if hostname.blank?
      return render json: { error: 'Hostname is required' }, status: :unprocessable_entity
    end

    # Check if domain already exists
    existing = CompanyDomain.find_by(hostname: hostname)
    if existing
      return render json: {
        error: "Domain #{hostname} is already registered"
      }, status: :unprocessable_entity
    end

    # Scoped lookup, so a website id from the request can only ever resolve to this
    # company's own site.
    website_id = params[:website_id].presence
    if website_id.present? && !@company.websites.exists?(id: website_id)
      return render json: { error: 'That website does not belong to this company' },
                    status: :unprocessable_entity
    end

    # Create domain record
    domain = @company.company_domains.build(
      hostname: hostname,
      website_id: website_id,
      force_ssl: params[:force_ssl] != false,
      force_www: params[:force_www] || false,
      redirect_type: params[:redirect_type] || 'none',
      verification_status: 'pending',
      web_enabled: wants_web
    )

    unless domain.save
      return render json: {
        error: domain.errors.full_messages.join(', ')
      }, status: :unprocessable_entity
    end

    unless wants_web
      return render json: {
        domain: domain_json(domain),
        message: 'Domain added. Enable email sending to get the DNS records to publish.'
      }, status: :created
    end

    # Add to Cloudflare
    provisioned_hostname_id = nil
    begin
      cloudflare_service = CloudflareSaasService.new
      cf_response = cloudflare_service.add_custom_hostname(hostname)

      # Parse response and update domain
      parsed = cloudflare_service.parse_custom_hostname_response(cf_response)
      # Held separately so cleanup can still reach it if the write below fails, which is
      # exactly when the hostname is live in Cloudflare but unrecorded here.
      provisioned_hostname_id = parsed[:custom_hostname_id]
      domain.update!(
        cloudflare_custom_hostname_id: parsed[:custom_hostname_id],
        verification_status: parsed[:verification_status],
        verification_records: parsed[:verification_records],
        ssl_status: parsed[:ssl_status],
        # Our configured target, not parsed[:cname_target]. That field carried Cloudflare's
        # ownership token, which is a TXT value and not something anyone can CNAME to.
        cname_target: cloudflare_service.cname_target
      )
      
      # Without a route the Worker never runs for this hostname and Render answers 403.
      # Best effort: a domain that provisioned is still worth keeping, and the route can be
      # added later, so this does not fail the request.
      cloudflare_service.create_worker_route(hostname)

      Rails.logger.info "[CompanyDomains] Created domain #{hostname} for company #{@company.id}"
      
      render json: { 
        domain: domain_json(domain.reload),
        message: 'Custom domain added successfully. Please configure DNS records.' 
      }, status: :created
      
    rescue CloudflareSaasService::CloudflareError => e
      domain.destroy
      Rails.logger.error "[CompanyDomains] Cloudflare error: #{e.message}"
      render json: { error: "Cloudflare error: #{e.message}" }, status: :unprocessable_entity
    rescue StandardError => e
      # Anything after a successful Cloudflare call leaves a hostname live there and a
      # half-written record here. Without this the row survived, so retrying reported the
      # domain as already registered and the tenant was stuck with no way forward.
      Rails.logger.error "[CompanyDomains] Failed after provisioning #{hostname}: #{e.class}: #{e.message}"
      release_custom_hostname(provisioned_hostname_id)
      domain.destroy
      render json: { error: 'Could not finish setting up this domain. Please try again.' },
             status: :unprocessable_entity
    end
  end
  
  # PATCH /api/v1/company_domains/:id
  def update
    return unless authorize_action!('company_settings', 'update')
    
    update_params = params.permit(:force_ssl, :force_www, :redirect_type, :website_id)

    # Never take a website id on trust. Scoping the lookup to the company is what stops a
    # domain being pointed at another tenant's site by guessing an id.
    if update_params.key?(:website_id)
      website_id = update_params[:website_id].presence
      if website_id.present? && !@company.websites.exists?(id: website_id)
        return render json: { error: 'That website does not belong to this company' },
                      status: :unprocessable_entity
      end

      update_params[:website_id] = website_id
    end

    if @domain.update(update_params)
      render json: { 
        domain: domain_json(@domain),
        message: 'Domain settings updated' 
      }
    else
      render json: { error: @domain.errors.full_messages.join(', ') }, status: :unprocessable_entity
    end
  end
  
  # DELETE /api/v1/company_domains/:id
  #
  # One record can serve the website and email independently, so this removes the website
  # role rather than the record. Destroying outright would silently take a verified sending
  # domain with it, and the tenant would have no reason to expect that from a button on the
  # website card. Re-verifying an email domain means republishing DNS, so this is a costly
  # thing to lose by accident.
  def destroy
    return unless authorize_action!('company_settings', 'update')

    hostname = @domain.hostname

    # Delete from Cloudflare first if it exists
    if @domain.cloudflare_custom_hostname_id.present?
      begin
        cloudflare_service = CloudflareSaasService.new
        cloudflare_service.delete_custom_hostname(@domain.cloudflare_custom_hostname_id)
        # Otherwise the zone accumulates a route per domain ever removed, each still sending
        # that hostname through the Worker.
        cloudflare_service.delete_worker_route(hostname)
      rescue CloudflareSaasService::CloudflareError => e
        Rails.logger.warn "[CompanyDomains] Failed to delete from Cloudflare: #{e.message}"
        # Continue with local removal anyway
      end
    end

    if @domain.email_enabled?
      @domain.update!(
        web_enabled: false,
        cloudflare_custom_hostname_id: nil,
        verification_status: 'pending',
        ssl_status: nil,
        active: false
      )

      Rails.logger.info "[CompanyDomains] Removed website role from #{hostname} (company #{@company.id}); email sending kept"

      return render json: {
        message: 'Website domain removed. This domain is still verified for sending email.',
        domain: domain_json(@domain.reload)
      }
    end

    @domain.destroy

    Rails.logger.info "[CompanyDomains] Deleted domain #{hostname} for company #{@company.id}"

    render json: { message: 'Website domain removed' }
  end
  
  # POST /api/v1/company_domains/:id/verify
  def verify
    return unless authorize_action!('company_settings', 'update')
    
    unless @domain.cloudflare_custom_hostname_id.present?
      return render json: { error: 'Domain not registered with Cloudflare' }, status: :unprocessable_entity
    end
    
    # Shares one implementation with the background poller, so pressing this and waiting for
    # the sweep can never disagree about what Cloudflare said.
    result = Websites::CloudflareStatusRefresher.call(@domain)

    unless result.updated
      Rails.logger.error "[CompanyDomains] Verification failed: #{result.error}"
      return render json: { error: result.error, verified: false }, status: :unprocessable_entity
    end

    @domain.reload

    message =
      if result.ready?
        'Domain verified and SSL certificate issued. Your custom domain is ready to use.'
      elsif result.verified
        'Domain verified. The certificate usually takes a few more minutes.'
      else
        'Verification pending. Confirm the DNS records below are published.'
      end

    render json: {
      domain: domain_json(@domain),
      message: message,
      verified: result.verified,
      ssl_pending: result.verified && !result.ssl_active
    }
  end
  
  # POST /api/v1/company_domains/:id/check_dns
  #
  # Checks the records Cloudflare actually issued for this hostname, whatever their type.
  # This used to look only for a CNAME on the hostname itself, so a correctly published
  # TXT ownership record reported "CNAME record not found" — telling a tenant who had done
  # everything right that they had done nothing. Cloudflare issues TXT ownership
  # verification for apex hostnames, where a CNAME is not even legal.
  def check_dns
    return unless authorize_action!('company_settings', 'read')

    # A domain Cloudflare has already verified and issued a certificate for is finished, so
    # say so rather than re-deriving it from DNS. This reported "not ready" for a domain
    # that was serving traffic, because it was still demanding a stale ownership token
    # Cloudflare had long since stopped caring about.
    if @domain.verified? && @domain.ssl_active?
      return render json: {
        configured: true,
        message: 'This domain is set up and serving.',
        records: []
      }
    end

    # Checks the routing CNAME as well as Cloudflare's ownership records. Verifying only
    # ownership reported success while the site was still unreachable.
    expected = @domain.web_dns_records.map(&:stringify_keys)
    if expected.empty?
      return render json: { configured: false, message: 'No DNS records issued for this domain yet' }
    end

    results = expected.map { |record| check_expected_record(record).merge(required: record['required'] != false) }
    # Gated on the required records only. The optional ownership record is reported so a
    # tenant can see it landed, but its absence does not mean the setup is incomplete.
    configured = results.select { |r| r[:required] }.all? { |r| r[:found] }

    @domain.update(dns_checked_at: Time.current,
                   dns_error: configured ? nil : 'Waiting on DNS records')

    render json: {
      configured: configured,
      message: if configured
                 'DNS is pointing at us. The certificate is issued automatically and usually ' \
                 'takes a few minutes.'
               else
                 'Not all records are visible yet. DNS can take up to an hour to propagate.'
               end,
      records: results
    }
  rescue StandardError => e
    Rails.logger.error "[CompanyDomains] DNS check failed: #{e.message}"
    render json: { configured: false, message: "DNS lookup failed: #{e.message}" },
           status: :unprocessable_entity
  end
  
  # POST /api/v1/company_domains/:id/activate
  def activate
    return unless authorize_action!('company_settings', 'update')
    
    unless @domain.verified? && @domain.ssl_active?
      return render json: { 
        error: 'Domain must be verified and have active SSL before activation' 
      }, status: :unprocessable_entity
    end
    
    @domain.activate!
    
    render json: { 
      domain: domain_json(@domain),
      message: 'Custom domain activated' 
    }
  end
  
  # POST /api/v1/company_domains/:id/deactivate
  def deactivate
    return unless authorize_action!('company_settings', 'update')
    
    @domain.deactivate!
    
    render json: { 
      domain: domain_json(@domain),
      message: 'Custom domain deactivate' 
    }
  end
  
  # POST /api/v1/company_domains/:id/enable_email
  # Registers the domain as an SES sending identity and returns the DNS records to publish.
  def enable_email
    return unless authorize_action!('company_settings', 'update')

    # Gates verifying a new domain, not sending. A tenant who downgrades keeps any domain
    # they already verified and keeps sending through it; revoking mid-campaign would
    # silently reroute live sends back through personal mailboxes.
    unless sending_domain_module_enabled?
      return render json: {
        error: 'Sending Domain is not enabled for this account.',
        module_key: SENDING_DOMAIN_MODULE
      }, status: :forbidden
    end

    begin
      Ses::IdentityManager.new(@domain).create_identity!
    rescue Ses::IdentityManager::SesError => e
      return render json: { error: e.message }, status: :unprocessable_entity
    end

    render json: {
      domain: domain_json(@domain.reload),
      message: 'Publish these DNS records, then check status. Verification usually takes ' \
               'a few minutes but can take up to 72 hours.'
    }
  end

  # POST /api/v1/company_domains/:id/check_email
  # Asks SES whether it can sign for this domain yet. SES is the authority here; we never
  # infer verification from our own DNS lookups.
  def check_email
    return unless authorize_action!('company_settings', 'read')

    unless @domain.email_enabled?
      return render json: { error: 'Email sending is not enabled for this domain' },
                    status: :unprocessable_entity
    end

    begin
      Ses::IdentityManager.new(@domain).refresh_status!
    rescue Ses::IdentityManager::SesError => e
      return render json: { error: e.message, verified: false }, status: :unprocessable_entity
    end

    @domain.reload

    render json: {
      domain: domain_json(@domain),
      verified: @domain.email_verified?,
      message: if @domain.email_verified?
                 'Domain verified. Campaigns can now send from this domain.'
               else
                 'Not verified yet. Confirm the DNS records are published exactly as shown.'
               end
    }
  end

  # GET /api/v1/company-domains/hostname-advice?hostname=example.com
  #
  # Checked before a tenant commits, because a bare domain fails in the least helpful way
  # possible: every step succeeds, ownership verifies, and then the certificate silently
  # never issues because DNS forbids a CNAME at a zone apex.
  def hostname_advice
    return unless authorize_action!('company_settings', 'read')

    advice = Dns::ApexAdvisor.for(params[:hostname])

    render json: {
      apex: advice.apex?,
      workable: advice.workable?,
      strategy: advice.strategy,
      headline: advice.headline,
      detail: advice.detail,
      suggested_hostname: advice.suggested_hostname,
      registrar_name: advice.registrar_name
    }
  end

  # GET /api/v1/company_domains/:id/domain_connect
  #
  # Whether this domain's DNS provider can apply our records automatically, and the link to
  # send the admin to if so. Always safe to call: an unsupported provider (Cloudflare does
  # not implement Domain Connect at all) simply reports supported: false and the tenant
  # publishes the records by hand.
  def domain_connect
    return unless authorize_action!('company_settings', 'read')

    unless @domain.email_enabled?
      return render json: { supported: false, reason: 'Email sending is not enabled for this domain' }
    end

    discovery = DomainConnect::Discovery.call(@domain.hostname)
    apply_url = DomainConnect::ApplyLink.for(domain: @domain, discovery: discovery)

    render json: {
      supported: discovery.supported? && apply_url.present?,
      provider_name: discovery.provider_name,
      apply_url: apply_url,
      width: discovery.width,
      height: discovery.height,
      # Distinguishes "your registrar cannot do this" from "we have not finished onboarding
      # with your registrar yet", which are different problems for the tenant.
      reason: if !discovery.supported?
                discovery.error
              elsif apply_url.blank?
                'Automatic setup is not available for this provider yet'
              end
    }
  end

  # POST /api/v1/company_domains/:id/disable_email
  def disable_email
    return unless authorize_action!('company_settings', 'update')

    Ses::IdentityManager.new(@domain).delete_identity!

    @domain.update!(
      email_enabled: false,
      email_verified_at: nil,
      ses_identity_status: nil,
      ses_dkim_tokens: [],
      ses_mail_from_domain: nil,
      ses_mail_from_status: nil,
      ses_error: nil
    )

    render json: {
      domain: domain_json(@domain),
      message: 'Email sending disabled. Campaigns fall back to connected mailboxes.'
    }
  end

  private

  def set_domain
    @domain = @company.company_domains.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Domain not found' }, status: :not_found
  end
  
  # Resolves one expected record and reports whether it is live. Compares against the value
  # Cloudflare issued rather than looking for our own hostname, because for TXT ownership
  # the value is an opaque token that appears nowhere else.
  def check_expected_record(record)
    name = record['name'].to_s
    type = record['type'].to_s.upcase
    expected_value = record['value'].to_s

    found_values =
      case type
      when 'TXT'   then Dns::Lookup.txt(name)
      when 'CNAME' then Dns::Lookup.cname(name)
      when 'MX'    then Dns::Lookup.mx(name)
      else []
      end

    {
      type: type,
      name: name,
      expected: expected_value,
      found: found_values.any? { |v| v.to_s.chomp('.').casecmp?(expected_value.chomp('.')) },
      found_values: found_values
    }
  rescue StandardError => e
    Rails.logger.warn "[CompanyDomains] lookup failed for #{record['name']}: #{e.message}"
    { type: record['type'], name: record['name'], expected: record['value'], found: false, found_values: [] }
  end

  # Best-effort cleanup so a failed setup does not strand a hostname in Cloudflare that
  # blocks the tenant from ever adding that domain again.
  def release_custom_hostname(id)
    return if id.blank?

    CloudflareSaasService.new.delete_custom_hostname(id)
  rescue StandardError => e
    Rails.logger.warn "[CompanyDomains] Could not release Cloudflare hostname #{id}: #{e.message}"
  end

  # Only while something still needs publishing. The lookup costs a DNS query and is noise
  # once a domain is finished.
  # Scoped to the company, so a domain can never be pointed at another tenant's site, and
  # to the selected location so this list matches what the website builder shows. Without
  # the location scope the picker offered sites from every location, which reads as another
  # tenant's data leaking in even though it never was.
  #
  # Drafts are offered too: dealers routinely wire up the address before publishing, and
  # HostResolver refuses to serve an unpublished site anyway.
  def assignable_websites
    # .sites: the marketing container is not offered here. Pointing a dealer's
    # domain at their landing page container instead of their actual site is a
    # mistake with no obvious symptom, and the name in this dropdown would not
    # make the difference clear. Serving landing pages from a custom domain is a
    # separate, deliberate action.
    @company.websites
            .sites
            .where(is_deleted: [false, nil])
            .for_current_location
            .order(:name)
            .map { |w| { id: w.id, name: w.name, slug: w.slug, status: w.status, published: w.status == 'published' } }
  rescue StandardError => e
    Rails.logger.error "[CompanyDomains] Could not list websites: #{e.message}"
    []
  end

  def domain_needs_dns_help?(domain)
    (domain.email_enabled? && !domain.email_verified?) ||
      (domain.web_enabled? && !domain.ready_for_use?)
  end

  def apex_forwarding_advice(domain)
    apex = domain.apex_needing_forwarding
    return nil if apex.blank?
    return nil unless domain_needs_dns_help?(domain)

    {
      apex: apex,
      target: "https://#{domain.hostname}",
      hint: Dns::Registrar.for(domain.hostname)[:forwarding_hint]
    }
  end

  def sending_domain_module_enabled?
    ModuleAccessService.new(@company).module_enabled?(SENDING_DOMAIN_MODULE)
  rescue StandardError => e
    Rails.logger.error "[CompanyDomains] module check failed: #{e.message}"
    false
  end

  def cloudflare_enabled?
    # Ask the service rather than re-reading config here. This used to check encrypted
    # credentials directly, so setting the env vars would leave the UI reporting Cloudflare
    # as unavailable while the service itself worked fine.
    CloudflareSaasService.configured?
  end
  
  def domain_json(domain)
    {
      id: domain.id,
      hostname: domain.hostname,
      domain_root: domain.domain_root,
      full_url: domain.full_url,
      
      # Status
      active: domain.active,
      # Whether this domain is used for website hosting. A domain added only for sending
      # email has never been through Cloudflare, so showing it in the website list leaves
      # it stuck on "DNS Verification Pending" forever.
      web_enabled: domain.web_enabled,
      verification_status: domain.verification_status,
      ssl_status: domain.ssl_status,
      ready_for_use: domain.ready_for_use?,
      
      # DNS configuration
      # Which site this address serves. Null means the domain resolves but has nothing to
      # show, which surfaces as the platform root rather than as an error.
      website_id: domain.website_id,
      website_name: domain.website&.name,
      website_published: domain.website&.status == 'published',

      cname_target: domain.cname_target,
      verification_records: domain.dns_records_for_display,
      # Ownership records plus the CNAME that actually routes traffic. The latter is our
      # configuration, so Cloudflare never includes it and it would otherwise never be shown.
      web_dns_records: domain.web_dns_records,
      dns_checked_at: domain.dns_checked_at,
      dns_error: domain.dns_error,
      
      # SSL certificate
      ssl_issued_at: domain.ssl_issued_at,
      ssl_expires_at: domain.ssl_expires_at,

      # Email sending (SES identity)
      email_enabled: domain.email_enabled,
      email_status: domain.email_status,
      email_verified: domain.email_verified?,
      email_verified_at: domain.email_verified_at,
      email_dns_records: domain.email_dns_records,
      # Where this domain's DNS is actually managed, so the screen can give instructions for
      # that provider rather than generic ones. Only looked up when there are records to
      # publish; it costs an NS query and is useless otherwise.
      dns_registrar: domain_needs_dns_help?(domain) ? Dns::Registrar.for(domain.hostname) : nil,
      # Forwarding the bare domain is a registrar setting, not a DNS record, so it cannot
      # appear in the record list. Left unsaid, a dealer whose www site works finds their
      # bare domain still on a parking page and concludes the setup failed.
      apex_forwarding: apex_forwarding_advice(domain),
      ses_identity_status: domain.ses_identity_status,
      ses_mail_from_domain: domain.ses_mail_from_domain,
      ses_mail_from_status: domain.ses_mail_from_status,
      ses_checked_at: domain.ses_checked_at,
      ses_error: domain.ses_error,
      
      # Settings
      force_ssl: domain.force_ssl,
      force_www: domain.force_www,
      redirect_type: domain.redirect_type,
      
      # Metadata
      activated_at: domain.activated_at,
      deactivated_at: domain.deactivated_at,
      created_at: domain.created_at,
      updated_at: domain.updated_at
    }
  end
end
