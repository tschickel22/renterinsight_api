# == Schema Information
#
# Table name: company_domains
#
#  id                            :bigint           not null, primary key
#  company_id                    :bigint           not null
#  website_id                    :bigint
#  hostname                      :string           not null
#  domain_root                   :string
#  cloudflare_custom_hostname_id :string
#  verification_status           :string
#  verification_records          :jsonb
#  ssl_status                    :string
#  ssl_issued_at                 :datetime
#  ssl_expires_at                :datetime
#  cname_target                  :string
#  dns_checked_at                :datetime
#  dns_error                     :string
#  active                        :boolean          default(FALSE)
#  activated_at                  :datetime
#  deactivated_at                :datetime
#  force_ssl                     :boolean          default(TRUE)
#  force_www                     :boolean          default(FALSE)
#  redirect_type                 :string
#  created_at                    :datetime         not null
#  updated_at                    :datetime         not null

class CompanyDomain < ApplicationRecord
  belongs_to :company
  belongs_to :website, optional: true
  
  # Validations
  validates :hostname, presence: true, uniqueness: true
  validates :hostname, format: { 
    with: /\A[a-z0-9]+([\-\.]{1}[a-z0-9]+)*\.[a-z]{2,}\z/i,
    message: 'must be a valid domain name'
  }
  # verification_status and ssl_status hold whatever Cloudflare reports, deliberately
  # unvalidated. They are a third party's vocabulary, not ours, and it is far larger than it
  # looks: SSL alone can be initializing, pending_validation, pending_issuance,
  # pending_deployment, staging_deployment, holding_deployment, several *_timed_out values
  # and more, and Cloudflare adds to the list over time.
  #
  # These used to be validated against four values each. A successful provisioning then
  # failed on our own validation, leaving the hostname live in Cloudflare and the record
  # half-written, so the retry reported the domain as already registered. Rejecting a status
  # a vendor legitimately returned buys nothing: the code that cares compares against
  # 'active' and treats everything else as not ready.
  validates :redirect_type, inclusion: {
    in: %w[www_to_non_www non_www_to_www none],
    allow_nil: true
  }
  
  # Scopes
  scope :active, -> { where(active: true) }
  scope :pending_verification, -> { where(verification_status: 'pending') }
  scope :verified, -> { where(verification_status: 'active') }
  scope :ssl_active, -> { where(ssl_status: 'active') }

  # Email sending
  scope :email_enabled, -> { where(email_enabled: true) }
  scope :email_verified, -> { email_enabled.where.not(email_verified_at: nil) }
  scope :email_pending, -> { email_enabled.where(email_verified_at: nil) }
  
  # Callbacks
  before_validation :extract_domain_root
  before_validation :normalize_hostname
  
  # Status checks
  def pending?
    verification_status == 'pending'
  end
  
  def verified?
    verification_status == 'active'
  end
  
  def ssl_active?
    ssl_status == 'active'
  end
  
  def ready_for_use?
    verified? && ssl_active? && active
  end
  
  # Domain utilities
  def full_url
    "https://#{hostname}"
  end
  
  def display_name
    hostname
  end
  
  # Activation
  def activate!
    update!(
      active: true,
      activated_at: Time.current,
      deactivated_at: nil
    )
  end
  
  def deactivate!
    update!(
      active: false,
      deactivated_at: Time.current
    )
  end
  
  # DNS verification
  def requires_dns_verification?
    pending? && verification_records.present?
  end
  
  def dns_records_for_display
    return [] unless verification_records.present?

    verification_records.map do |record|
      {
        type: record['type'],
        name: record['name'] || hostname,
        value: record['value'],
        ttl: record['ttl'] || 3600
      }
    end
  end

  # Everything a tenant has to publish for the website to work: Cloudflare's ownership
  # records, plus the CNAME that actually routes traffic.
  #
  # The CNAME is the one that matters and the one Cloudflare never mentions. Showing only
  # the ownership record produced a domain that verified ownership, reported success at
  # every step, and then sat forever without a certificate, because nothing pointed at us.
  def web_dns_records
    # Required, despite the theory that a CNAME pointing at us proves ownership on its own.
    # Measured on a real hostname: with the CNAME live and resolving to Cloudflare, HTTP
    # returned 409 (custom hostname not active) and no certificate issued until the
    # ownership record was published. HTTP validation cannot bootstrap ownership, because
    # Cloudflare will not serve the hostname before ownership exists.
    records = dns_records_for_display.map do |r|
      r.merge(
        purpose: 'Proves you control this domain. The certificate cannot be issued without it.',
        required: true
      )
    end

    if cname_target.present?
      records << {
        type: 'CNAME',
        name: hostname,
        value: cname_target,
        ttl: 3600,
        purpose: 'Points your domain at us. Without this the site never loads and the ' \
                 'certificate cannot be issued.',
        required: true
      }
    end

    records
  end
  
  # ==================== EMAIL SENDING ====================

  # True only when SES itself reports DKIM success. Never inferred from our own DNS
  # lookups: the old companies.email_domain path called a domain verified whenever any SPF
  # and any DMARC record resolved, which reported success for domains configured entirely
  # for someone else.
  def email_verified?
    email_enabled? && email_verified_at.present?
  end

  def email_pending?
    email_enabled? && email_verified_at.nil?
  end

  # The records a tenant publishes to let us sign as them. Three DKIM CNAMEs from SES,
  # plus the MAIL FROM MX and SPF pair that make SPF align with the From header instead of
  # falling through to amazonses.com.
  def email_dns_records
    return [] unless email_enabled?

    records = Array(ses_dkim_tokens).map do |token|
      {
        type: 'CNAME',
        name: "#{token}._domainkey.#{hostname}",
        host: "#{token}._domainkey",
        value: "#{token}.dkim.amazonses.com",
        ttl: 1800,
        purpose: 'DKIM signature. Required before any mail can be sent from this domain.',
        required: true
      }
    end

    if ses_mail_from_domain.present?
      records << {
        type: 'MX',
        name: ses_mail_from_domain,
        host: relative_host(ses_mail_from_domain),
        value: "feedback-smtp.#{ses_region}.amazonses.com",
        priority: 10,
        ttl: 1800,
        purpose: 'Routes bounce and complaint reports back to us.',
        required: false
      }
      records << {
        type: 'TXT',
        name: ses_mail_from_domain,
        host: relative_host(ses_mail_from_domain),
        value: 'v=spf1 include:amazonses.com ~all',
        ttl: 1800,
        purpose: 'SPF alignment for the bounce domain.',
        required: false
      }
    end

    records
  end

  # Human-facing summary of where verification stands, for the settings screen.
  def email_status
    return 'disabled' unless email_enabled?
    return 'failed'   if ses_error.present? && email_verified_at.nil?
    return 'verified' if email_verified_at.present?

    'pending'
  end

  private

  # Nearly every DNS provider treats the host field as relative to the zone, so pasting the
  # fully qualified name creates token._domainkey.example.com.example.com and the record
  # never verifies. Both spellings are exposed so the UI can show whichever the tenant's
  # provider actually wants.
  def relative_host(fqdn)
    fqdn.to_s.delete_suffix(".#{hostname}").presence || '@'
  end

  def ses_region
    Ses::Region.current
  end

  def extract_domain_root
    return if hostname.blank?
    
    # Extract root domain (e.g., example.com from www.example.com)
    parts = hostname.split('.')
    if parts.length >= 2
      self.domain_root = parts[-2..-1].join('.')
    else
      self.domain_root = hostname
    end
  end
  
  def normalize_hostname
    return if hostname.blank?
    
    # Remove protocol, trailing slashes, convert to lowercase
    self.hostname = hostname.downcase
                            .gsub(/^https?:\/\//, '')
                            .gsub(/\/$/, '')
                            .strip
  end
end
