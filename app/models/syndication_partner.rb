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
  #
  # The host comes from configuration, never a hardcoded brand domain:
  # PUBLIC_FEED_BASE_URL wins, then RAILS_API_URL (the API's own public
  # address, which provider webhooks already use), then the local dev server.
  def self.feed_base_url
    (ENV['PUBLIC_FEED_BASE_URL'].presence ||
      ENV['RAILS_API_URL'].presence ||
      'https://localhost:3001').chomp('/')
  end

  # The address to give the partner, built from the current host. The stored
  # feed_url column can still hold an old host written before a rebrand.
  def public_feed_url
    return nil if feed_token.blank?

    "#{self.class.feed_base_url}/public/feeds/#{id}?token=#{feed_token}"
  end

  def generate_feed_url
    return if feed_url.present?

    regenerate_feed_url
  end

  def regenerate_feed_url
    token = SecureRandom.urlsafe_base64(32)
    update_column(:feed_token, token)
    update_column(:feed_url, public_feed_url)
  end

  def update_feed_url_format
    # Keep the existing token; only refresh the stored address.
    update_column(:feed_url, public_feed_url) if feed_token.present?
  end

  # ---- What the feed actually carries ------------------------------------
  #
  # The public feed narrows the stored listing_types by format: the MH Village
  # style feeds (json/xml) carry manufactured homes for sale, the RVT feed
  # carries RVs for sale, and MITS (mits_xml) carries rentals only. These two
  # methods are the single source for that rule, used by the feed itself and
  # by the dealer Listing Partners tab so the tab says what is really sent.

  # Vehicle listing types the feed sends, or nil when any type is sent.
  def feed_listing_types
    forced =
      case format
      when 'json', 'xml' then rvt? ? ['rv'] : ['manufactured_home']
      end
    stored = listing_types.presence
    return stored if forced.nil?
    return forced if stored.nil?

    stored & forced
  end

  # Listing offer types the feed sends.
  def feed_offer_types
    feed_format_mits_xml? ? %w[rent both] : %w[sale both]
  end

  # For the dealer tab: the kinds of home really sent (only types a vehicle
  # can have), and whether they go out for sale or for rent.
  def dealer_sends
    types = feed_listing_types
    types = types.nil? ? Vehicle::TYPES.dup : (types & Vehicle::TYPES)
    { listingTypes: types, offer: feed_format_mits_xml? ? 'rent' : 'sale' }
  end

  # Only the json/xml feed builders send a dealer's own account number. The
  # MITS builder identifies each dealer by its company id.
  def sends_dealer_account_id?
    feed_format_json? || feed_format_xml?
  end

  # ---- Per-dealer identifier --------------------------------------------
  #
  # Partners are set up once by platform admins and their feed carries every
  # dealer's published listings. Each dealer may have its own account number
  # at the partner site, saved by that dealer on the Listing Partners tab.
  # The feed sends that number for the dealer's own listings and falls back to
  # our company id. It never sends one dealer's number on another's homes.
  DEALER_ACCOUNT_SETTING_KEY = 'listing_partner_dealer_ids'

  def self.dealer_account_ids_for(company_id)
    raw = Setting.get('Company', company_id, DEALER_ACCOUNT_SETTING_KEY)
    raw.is_a?(Hash) ? raw : {}
  end

  def dealer_account_id_for(company)
    return nil unless company

    @dealer_account_ids ||= {}
    ids = @dealer_account_ids[company.id] ||= self.class.dealer_account_ids_for(company.id)
    ids[id.to_s].presence
  end

  def dealer_identifier_for(company)
    dealer_account_id_for(company) || company&.id
  end

  def set_dealer_account_id!(company, value)
    ids = self.class.dealer_account_ids_for(company.id).deep_stringify_keys
    value = value.to_s.strip
    if value.present?
      ids[id.to_s] = value
    else
      ids.delete(id.to_s)
    end
    Setting.set('Company', company.id, DEALER_ACCOUNT_SETTING_KEY, ids)
    @dealer_account_ids&.delete(company.id)
    value.presence
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
