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
  validates :verification_status, inclusion: { 
    in: %w[pending active moved deleted failed], 
    allow_nil: true 
  }
  validates :ssl_status, inclusion: { 
    in: %w[pending active expired failed], 
    allow_nil: true 
  }
  validates :redirect_type, inclusion: {
    in: %w[www_to_non_www non_www_to_www none],
    allow_nil: true
  }
  
  # Scopes
  scope :active, -> { where(active: true) }
  scope :pending_verification, -> { where(verification_status: 'pending') }
  scope :verified, -> { where(verification_status: 'active') }
  scope :ssl_active, -> { where(ssl_status: 'active') }
  
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
  
  private
  
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
