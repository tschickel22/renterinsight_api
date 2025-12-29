# frozen_string_literal: true

class SyndicationPartner < ApplicationRecord
  # Associations
  belongs_to :company
  
  # Constants
  PARTNER_TYPES = %w[mh_village rv_trader rvt zillow apartments_com apartment_list trulia facebook_marketplace other].freeze
  FORMATS = %w[json xml mits_xml].freeze
  LISTING_TYPES = %w[manufactured_home rv apartment rental both].freeze
  
  # Validations
  validates :name, presence: true
  validates :partner_type, presence: true, inclusion: { in: PARTNER_TYPES }
  validates :format, presence: true, inclusion: { in: FORMATS }
  validates :lead_email, format: { with: URI::MailTo::EMAIL_REGEXP }, allow_blank: true
  
  # Scopes
  scope :active, -> { where(active: true) }
  scope :inactive, -> { where(active: false) }
  scope :by_type, ->(type) { where(partner_type: type) }
  scope :by_format, ->(format) { where(format: format) }
  scope :mh_village, -> { where(partner_type: 'mh_village') }
  scope :rv_trader, -> { where(partner_type: 'rv_trader') }
  scope :rvt, -> { where(partner_type: 'rvt') }
  scope :recent, -> { order(created_at: :desc) }
  
  # Callbacks
  before_validation :normalize_fields
  after_create :generate_feed_url
  after_update :update_feed_url_format, if: :saved_change_to_format?
  
  # Status helpers
  def active?
    active == true
  end
  
  def inactive?
    !active?
  end
  
  # Toggle activation
  def toggle_active!
    update!(active: !active)
  end
  
  def activate!
    update!(active: true)
  end
  
  def deactivate!
    update!(active: false)
  end
  
  # Explicitly regenerate token (e.g., if compromised)
  def regenerate_token!
    regenerate_feed_url
  end
  
  # Listing type helpers
  def supports_listing_type?(type)
    return true if listing_types.empty? || listing_types.include?('both')
    listing_types.include?(type.to_s)
  end
  
  def supports_manufactured_homes?
    supports_listing_type?('manufactured_home')
  end
  
  def supports_rvs?
    supports_listing_type?('rv')
  end
  
  # Feed URL generation
  def generate_feed_url
    return if feed_url.present?
    
    # Use environment-appropriate base URL
    base_url = if Rails.env.development?
      'https://localhost:3001'
    elsif Rails.env.staging?
      ENV.fetch('PUBLIC_FEED_BASE_URL', 'https://renterinsight-api-staging.onrender.com')
    else
      ENV.fetch('PUBLIC_FEED_BASE_URL', 'https://api.landlordinsight.com')
    end
    
    token = SecureRandom.urlsafe_base64(32)
    
    update_column(:feed_url, "#{base_url}/public/feeds/#{id}?token=#{token}")
    update_column(:feed_token, token)
  end
  
  def regenerate_feed_url
    # Use environment-appropriate base URL
    base_url = if Rails.env.development?
      'https://localhost:3001'
    elsif Rails.env.staging?
      ENV.fetch('PUBLIC_FEED_BASE_URL', 'https://renterinsight-api-staging.onrender.com')
    else
      ENV.fetch('PUBLIC_FEED_BASE_URL', 'https://api.landlordinsight.com')
    end
    
    token = SecureRandom.urlsafe_base64(32)
    
    update_column(:feed_url, "#{base_url}/public/feeds/#{id}?token=#{token}")
    update_column(:feed_token, token)
  end
  
  def update_feed_url_format
    # Just update the feed_url without changing the token
    # This preserves the existing token when only format changes
    base_url = if Rails.env.development?
      'https://localhost:3001'
    elsif Rails.env.staging?
      ENV.fetch('PUBLIC_FEED_BASE_URL', 'https://renterinsight-api-staging.onrender.com')
    else
      ENV.fetch('PUBLIC_FEED_BASE_URL', 'https://api.landlordinsight.com')
    end
    
    # Keep existing token
    update_column(:feed_url, "#{base_url}/public/feeds/#{id}?token=#{feed_token}")
  end
  
  # Sync tracking
  def mark_synced!
    update(last_sync_at: Time.current)
  end
  
  def never_synced?
    last_sync_at.nil?
  end
  
  def last_sync_display
    return 'Never' if never_synced?
    
    time_ago = Time.current - last_sync_at
    
    case time_ago
    when 0..60
      'Just now'
    when 61..3600
      "#{(time_ago / 60).to_i} minutes ago"
    when 3601..86400
      "#{(time_ago / 3600).to_i} hours ago"
    else
      "#{(time_ago / 86400).to_i} days ago"
    end
  end
  
  # Partner-specific settings
  def mh_village?
    partner_type == 'mh_village'
  end
  
  def rv_trader?
    partner_type == 'rv_trader'
  end
  
  def rvt?
    partner_type == 'rvt'
  end
  
  def zillow?
    partner_type == 'zillow'
  end
  
  def apartments_com?
    partner_type == 'apartments_com'
  end
  
  def apartment_list?
    partner_type == 'apartment_list'
  end
  
  def trulia?
    partner_type == 'trulia'
  end
  
  def facebook_marketplace?
    partner_type == 'facebook_marketplace'
  end
  
  def uses_mits_format?
    %w[zillow apartments_com apartment_list trulia].include?(partner_type)
  end
  
  # Feed configuration
  def feed_format_json?
    format == 'json'
  end
  
  def feed_format_xml?
    format == 'xml'
  end
  
  def feed_format_mits_xml?
    format == 'mits_xml'
  end
  
  private
  
  def normalize_fields
    self.partner_type = partner_type&.downcase
    self.format = format&.downcase
    self.listing_types = listing_types.map(&:downcase) if listing_types.present?
  end
  
  # Removed should_regenerate_feed_url? - format changes no longer regenerate tokens
end
