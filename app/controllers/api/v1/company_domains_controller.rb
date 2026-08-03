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
      cloudflare_enabled: cloudflare_enabled?
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

    # Create domain record
    domain = @company.company_domains.build(
      hostname: hostname,
      website_id: params[:website_id],
      force_ssl: params[:force_ssl] != false,
      force_www: params[:force_www] || false,
      redirect_type: params[:redirect_type] || 'none',
      verification_status: 'pending'
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
    begin
      cloudflare_service = CloudflareSaasService.new
      cf_response = cloudflare_service.add_custom_hostname(hostname)
      
      # Parse response and update domain
      parsed = cloudflare_service.parse_custom_hostname_response(cf_response)
      domain.update!(
        cloudflare_custom_hostname_id: parsed[:custom_hostname_id],
        verification_status: parsed[:verification_status],
        verification_records: parsed[:verification_records],
        ssl_status: parsed[:ssl_status],
        cname_target: parsed[:cname_target]
      )
      
      Rails.logger.info "[CompanyDomains] Created domain #{hostname} for company #{@company.id}"
      
      render json: { 
        domain: domain_json(domain.reload),
        message: 'Custom domain added successfully. Please configure DNS records.' 
      }, status: :created
      
    rescue CloudflareSaasService::CloudflareError => e
      domain.destroy
      Rails.logger.error "[CompanyDomains] Cloudflare error: #{e.message}"
      render json: { error: "Cloudflare error: #{e.message}" }, status: :unprocessable_entity
    end
  end
  
  # PATCH /api/v1/company_domains/:id
  def update
    return unless authorize_action!('company_settings', 'update')
    
    update_params = params.permit(:force_ssl, :force_www, :redirect_type)
    
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
  def destroy
    return unless authorize_action!('company_settings', 'update')
    
    # Delete from Cloudflare first if it exists
    if @domain.cloudflare_custom_hostname_id.present?
      begin
        cloudflare_service = CloudflareSaasService.new
        cloudflare_service.delete_custom_hostname(@domain.cloudflare_custom_hostname_id)
      rescue CloudflareSaasService::CloudflareError => e
        Rails.logger.warn "[CompanyDomains] Failed to delete from Cloudflare: #{e.message}"
        # Continue with local deletion anyway
      end
    end
    
    @domain.destroy
    
    Rails.logger.info "[CompanyDomains] Deleted domain #{@domain.hostname} for company #{@company.id}"
    
    render json: { message: 'Custom domain removed' }
  end
  
  # POST /api/v1/company_domains/:id/verify
  def verify
    return unless authorize_action!('company_settings', 'update')
    
    unless @domain.cloudflare_custom_hostname_id.present?
      return render json: { error: 'Domain not registered with Cloudflare' }, status: :unprocessable_entity
    end
    
    begin
      cloudflare_service = CloudflareSaasService.new
      cf_response = cloudflare_service.check_custom_hostname_status(@domain.cloudflare_custom_hostname_id)
      
      # Parse and update status
      parsed = cloudflare_service.parse_custom_hostname_response(cf_response)
      @domain.update!(
        verification_status: parsed[:verification_status],
        ssl_status: parsed[:ssl_status],
        ssl_issued_at: parsed[:ssl_status] == 'active' ? Time.current : @domain.ssl_issued_at,
        dns_checked_at: Time.current,
        dns_error: nil
      )
      
      if @domain.verified? && @domain.ssl_active?
        @domain.activate! unless @domain.active?
        
        render json: { 
          domain: domain_json(@domain.reload),
          message: 'Domain verified and SSL certificate issued! Your custom domain is ready to use.',
          verified: true
        }
      elsif @domain.verified?
        render json: { 
          domain: domain_json(@domain.reload),
          message: 'Domain verified. Waiting for SSL certificate...',
          verified: true,
          ssl_pending: true
        }
      else
        render json: { 
          domain: domain_json(@domain.reload),
          message: 'Domain verification pending. Please check DNS configuration.',
          verified: false
        }
      end
      
    rescue CloudflareSaasService::CloudflareError => e
      @domain.update(dns_error: e.message, dns_checked_at: Time.current)
      Rails.logger.error "[CompanyDomains] Verification failed: #{e.message}"
      render json: { error: e.message, verified: false }, status: :unprocessable_entity
    end
  end
  
  # POST /api/v1/company_domains/:id/check_dns
  def check_dns
    return unless authorize_action!('company_settings', 'read')
    
    unless @domain.cname_target.present?
      return render json: { 
        configured: false, 
        message: 'No CNAME target available yet' 
      }
    end
    
    # Check if DNS is configured correctly
    begin
      require 'resolv'
      resolver = Resolv::DNS.new
      
      # Look up CNAME record
      cname_records = []
      begin
        cname_records = resolver.getresources(@domain.hostname, Resolv::DNS::Resource::IN::CNAME)
      rescue Resolv::ResolvError
        # No CNAME found, that's okay
      end
      
      configured = cname_records.any? { |r| r.name.to_s.include?('cloudflare') || r.name.to_s == @domain.cname_target }
      
      if configured
        @domain.update(dns_checked_at: Time.current, dns_error: nil)
        render json: { 
          configured: true,
          message: 'DNS is configured correctly',
          records_found: cname_records.map { |r| r.name.to_s }
        }
      else
        render json: { 
          configured: false,
          message: 'CNAME record not found or incorrect. Please add the DNS record.',
          expected: @domain.cname_target,
          records_found: cname_records.map { |r| r.name.to_s }
        }
      end
      
    rescue => e
      Rails.logger.error "[CompanyDomains] DNS check failed: #{e.message}"
      render json: { 
        configured: false, 
        message: "DNS lookup failed: #{e.message}" 
      }, status: :unprocessable_entity
    end
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
      verification_status: domain.verification_status,
      ssl_status: domain.ssl_status,
      ready_for_use: domain.ready_for_use?,
      
      # DNS configuration
      cname_target: domain.cname_target,
      verification_records: domain.dns_records_for_display,
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
      dns_registrar: domain.email_enabled? && !domain.email_verified? ? Dns::Registrar.for(domain.hostname) : nil,
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
