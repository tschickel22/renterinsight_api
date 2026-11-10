# frozen_string_literal: true

class LandParcel < ApplicationRecord
  # Associations
  belongs_to :company
  has_many :note_records, as: :entity, class_name: 'Note', dependent: :destroy
  # Homes offered together with this lot, each at its own package price.
  has_many :land_home_packages, dependent: :destroy
  
  # Constants
  # The built-in zoning choices, stored by these keys. A company can add its
  # own (stored as the text they typed, "R-1 Single Family") and remove or
  # reorder any of them under Company Settings, Customize, Land Zoning.
  ZONING_TYPES = %w[residential commercial agricultural industrial mixed_use].freeze
  ZONING_SETTING_KEY = 'land_zoning_options'
  ZONING_MAX_LENGTH = 60
  ZONING_MAX_OPTIONS = 50
  STATUSES = %w[available pending sold under_contract withdrawn].freeze
  
  # Validations
  validates :parcel_number, presence: true, uniqueness: { scope: :company_id }
  validates :status, presence: true, inclusion: { in: STATUSES }
  # Any text: a company's own choices are not a fixed list, and a choice
  # removed from the list stays on the parcels that already have it.
  validates :zoning_type, length: { maximum: ZONING_MAX_LENGTH }, allow_nil: true
  validates :acreage, numericality: { greater_than: 0 }, allow_nil: true
  validates :price, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :latitude, numericality: { greater_than_or_equal_to: -90, less_than_or_equal_to: 90 }, allow_nil: true
  # A Google Maps link, so the website never links buyers anywhere else.
  validates :street_view_url, format: { with: %r{\Ahttps://(www\.google\.com/maps|maps\.app\.goo\.gl/)}, message: 'must be a Google Maps Street View link' }, allow_blank: true
  validates :longitude, numericality: { greater_than_or_equal_to: -180, less_than_or_equal_to: 180 }, allow_nil: true
  
  # Scopes
  scope :active, -> { where(is_deleted: false) }
  scope :available, -> { active.where(status: 'available') }
  scope :sold, -> { active.where(status: 'sold') }
  scope :pending, -> { active.where(status: 'pending') }
  scope :under_contract, -> { active.where(status: 'under_contract') }
  scope :by_status, ->(status) { where(status: status) }
  scope :by_zoning, ->(zoning) { where(zoning_type: zoning) }
  scope :by_city, ->(city) { where('LOWER(city) = ?', city.to_s.downcase) }
  scope :by_state, ->(state) { where(state: state) }
  scope :by_price_range, ->(min, max) { where(price: min..max) }
  scope :by_acreage_range, ->(min, max) { where(acreage: min..max) }
  scope :search, ->(query) do
    operator = connection.adapter_name.downcase.include?('sqlite') ? 'LIKE' : 'ILIKE'
    where(
      "parcel_number #{operator} ? OR name #{operator} ? OR address #{operator} ? OR city #{operator} ? OR description #{operator} ?",
      "%#{query}%", "%#{query}%", "%#{query}%", "%#{query}%", "%#{query}%"
    )
  end
  scope :recent, -> { order(created_at: :desc) }
  
  # Callbacks
  before_validation :normalize_fields
  before_validation :calculate_price_per_acre
  before_validation :generate_parcel_number, on: :create
  
  # Soft delete
  def soft_delete!
    update!(is_deleted: true, deleted_at: Time.current)
  end
  
  def restore!
    update!(is_deleted: false, deleted_at: nil)
  end
  
  # Display helpers
  def display_name
    name.present? ? name : "Parcel #{parcel_number}"
  end
  
  def full_address
    parts = [address, city, state, zip].compact.reject(&:blank?)
    parts.any? ? parts.join(', ') : nil
  end
  
  def coordinates
    return nil unless latitude.present? && longitude.present?
    { latitude: latitude.to_f, longitude: longitude.to_f }
  end

  # Where the lot is, as the website may show it: the address and map pin when
  # the dealer shows the exact location, otherwise only the area.
  def public_location
    area = { city: city, state: state, zip: zip, county: county }
    return area.merge(exact_location: false) unless show_exact_location

    area.merge(exact_location: true, address: address, full_address: full_address,
               latitude: latitude&.to_f, longitude: longitude&.to_f, street_view_url: street_view_url.presence)
  end
  
  def has_utilities?
    utilities.present? && utilities.any? { |_k, v| v == true }
  end
  
  def utility_list
    return [] unless utilities.present?
    utilities.select { |_k, v| v == true }.keys.map(&:to_s)
  end
  
  # ---- zoning choices --------------------------------------------------

  def self.default_zoning_options
    ZONING_TYPES.map { |k| { 'value' => k, 'label' => k.humanize.titleize } }
  end

  # A built-in key in any casing or spacing ("Mixed Use", "MIXED_USE") is
  # stored as its key, so filters and old records keep matching. Anything else
  # is kept as typed, squished. Blank is nil.
  def self.normalize_zoning(value)
    text = value.to_s.squish
    return nil if text.blank?

    key = text.downcase.tr(' -', '__')
    ZONING_TYPES.include?(key) ? key : text.first(ZONING_MAX_LENGTH)
  end

  # A company that never changed them has the built-ins; one that cleared them has none.
  def self.zoning_options_for(company)
    saved = Setting.get('Company', company.id, ZONING_SETTING_KEY, nil)
    return default_zoning_options unless saved.is_a?(Array)

    saved.filter_map do |o|
      o = o.to_h.stringify_keys if o.respond_to?(:to_h)
      value = normalize_zoning(o.is_a?(Hash) ? (o['value'].presence || o['label']) : o)
      next unless value

      label = (o.is_a?(Hash) ? o['label'] : nil).to_s.squish.presence || zoning_label(value)
      { 'value' => value, 'label' => label }
    end
  end

  def self.save_zoning_options(company, options)
    clean = options.filter_map do |o|
      o = o.to_h.stringify_keys if o.respond_to?(:to_h)
      label = (o.is_a?(Hash) ? o['label'] : o).to_s.squish.first(ZONING_MAX_LENGTH)
      raw = o.is_a?(Hash) ? o['value'].presence || label : label
      value = normalize_zoning(raw)
      next unless value

      { 'value' => value, 'label' => label.presence || zoning_label(value) }
    end
    clean = clean.uniq { |o| o['value'].downcase }.first(ZONING_MAX_OPTIONS)
    Setting.set('Company', company.id, ZONING_SETTING_KEY, clean)
    clean
  end

  # Adds a choice from the land form. Returns the choice (an existing one when
  # the name matches, so two people typing "R-1" do not make two).
  def self.add_zoning_option(company, label)
    current = zoning_options_for(company)
    value = normalize_zoning(label)
    existing = current.find { |o| o['value'].casecmp?(value) || o['label'].casecmp?(label.to_s.squish) }
    return existing if existing

    option = { 'value' => value, 'label' => ZONING_TYPES.include?(value) ? zoning_label(value) : value }
    save_zoning_options(company, current + [option])
    option
  end

  # What a stored value reads as when no choice names it.
  def self.zoning_label(value)
    ZONING_TYPES.include?(value.to_s) ? value.to_s.humanize.titleize : value.to_s
  end

  private
  
  def normalize_fields
    self.state = state&.upcase
    self.status = status&.downcase
    self.zoning_type = self.class.normalize_zoning(zoning_type)
  end
  
  def calculate_price_per_acre
    if price.present? && acreage.present? && acreage > 0
      self.price_per_acre = price / acreage
    end
  end
  
  def generate_parcel_number
    return if parcel_number.present?
    
    prefix = 'LP'
    timestamp = Time.current.strftime('%Y%m%d')
    random = SecureRandom.hex(3).upcase
    
    self.parcel_number = "#{prefix}-#{timestamp}-#{random}"
  end
end
