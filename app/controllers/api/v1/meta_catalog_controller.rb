# frozen_string_literal: true

require 'csv'

# Public inventory feed for Meta Dynamic Ads. Meta polls this URL.
# Auth is via a company-scoped token (Authorization: Bearer <token>, or ?token=).
class Api::V1::MetaCatalogController < ApplicationController
  skip_before_action :authenticate, only: [:feed]
  before_action :set_company_scope, only: [:info, :regenerate_token, :update_settings]

  MAX_EXTRA_IMAGES = 9
  DEFAULT_MEDIUM   = 'catalog_ad'
  DEFAULT_CAMPAIGN = 'rotating_inventory'

  # Meta accepts CSV, TSV, XML (RSS/ATOM) or XLSX for a scheduled feed. It does
  # not accept JSON, and it validates the URL before fetching, so the link we
  # hand the dealer has to end in .csv or Commerce Manager rejects it outright.
  FEED_COLUMNS = %w[
    id title description availability condition price link image_link
    additional_image_link brand inventory
    custom_label_0 custom_label_1 custom_label_2 custom_label_3 custom_label_4
  ].freeze

  # Meta rejects a whole item if any of these is empty, and reports it back in
  # the feed's issue log rather than just ignoring it. Sending a row we already
  # know is incomplete buys nothing but an error report, so hold it back and
  # tell the dealer instead.
  REQUIRED_FEED_FIELDS = %i[id title description availability condition price link image_link].freeze

  SETTING_KEY        = 'meta_catalog_settings'
  ALLOWED_STATUSES   = %w[available available_to_order reserved sold pending in_transit delivered].freeze
  DEFAULT_STATUSES   = %w[available].freeze

  # GET /api/v1/meta/catalog/info
  def info
    return unless authorize_action!('integrations', 'read')

    token    = @company.meta_catalog_token
    statuses = catalog_statuses
    base_url = intake_form_url(@company)

    # Counted across every status the dealer could pick, not just the selected
    # ones, so the warning against a status is visible before it is ticked. An
    # Available to Order home usually has no price yet, and would never reach
    # the catalog however the feed is configured.
    vehicles = @company.vehicles.where(is_deleted: false, status: ALLOWED_STATUSES).order(id: :asc)

    excluded          = []
    excluded_by_status = Hash.new(0)
    eligible_by_status = Hash.new(0)

    # Same serialization the feed runs, so these counts are what Meta will
    # accept rather than how many rows we would send.
    vehicles.each do |v|
      item    = serialize(v, company: @company, base_url: base_url)
      missing = missing_feed_fields(item)
      status  = v.status.to_s

      if missing.empty?
        eligible_by_status[status] += 1
        next
      end

      excluded_by_status[status] += 1
      next unless statuses.include?(status)

      excluded << {
        id:      item[:id],
        title:   item[:title].presence || item[:id],
        status:  status,
        missing: missing.map(&:to_s)
      }
    end

    selected_eligible = statuses.sum { |st| eligible_by_status[st] }

    render json: {
      catalog: {
        token:         token,
        active_count:  selected_eligible,
        excluded_count: excluded.length,
        # Capped: this is a nudge to go fix the records, not a report.
        excluded:      excluded.first(25),
        excluded_by_status: excluded_by_status,
        eligible_by_status: eligible_by_status,
        feed_url:      token.present? ? catalog_feed_url : nil,
        last_sync_at:  nil,
        statuses:      statuses,
        allowed_statuses: ALLOWED_STATUSES
      }
    }
  end

  # PATCH /api/v1/meta/catalog/settings
  def update_settings
    return unless authorize_action!('integrations', 'update')

    requested = Array(params[:statuses]).map(&:to_s).select { |s| ALLOWED_STATUSES.include?(s) }.uniq
    requested = DEFAULT_STATUSES.dup if requested.empty?

    settings = load_settings
    settings['statuses'] = requested
    Setting.set('Company', @company.id, SETTING_KEY, settings)

    vehicle_count = @company.vehicles.where(is_deleted: false, status: requested).count

    render json: {
      catalog: {
        statuses:     requested,
        active_count: vehicle_count
      }
    }
  end

  # POST /api/v1/meta/catalog/regenerate_token
  def regenerate_token
    return unless authorize_action!('integrations', 'update')

    new_token = SecureRandom.urlsafe_base64(32)
    @company.update!(meta_catalog_token: new_token)

    render json: {
      catalog: {
        token: new_token,
        feed_url: catalog_feed_url
      }
    }
  end

  # GET /api/v1/meta/catalog/:company_id/feed
  def feed
    company = Company.find_by(id: params[:company_id])
    return head :not_found unless company

    token = bearer_token.presence || params[:token].to_s
    return head :unauthorized if token.blank?
    unless company.meta_catalog_token.present? && secure_equal?(token, company.meta_catalog_token)
      return head :unauthorized
    end

    base_url = intake_form_url(company)
    statuses = statuses_for(company)
    vehicles = company.vehicles
                      .where(is_deleted: false, status: statuses)
                      .order(id: :asc)

    items = vehicles.map { |v| serialize(v, company: company, base_url: base_url) }
                    .select { |item| missing_feed_fields(item).empty? }

    # JSON stays available for our own preview and debugging; CSV is the default
    # because it is what Meta can actually read.
    if params[:format].to_s.casecmp('json').zero?
      render json: items
    else
      send_data feed_csv(items),
                type:        'text/csv; charset=utf-8',
                disposition: 'inline',
                filename:    "inventory-#{company.id}.csv"
    end
  end

  private

  def catalog_statuses
    statuses_for(@company)
  end

  def statuses_for(company)
    raw = Setting.get('Company', company.id, SETTING_KEY)
    hash = case raw
           when Hash   then raw.deep_stringify_keys
           when String then (JSON.parse(raw).deep_stringify_keys rescue {})
           else              {}
           end
    list = Array(hash['statuses']).map(&:to_s).select { |s| ALLOWED_STATUSES.include?(s) }
    list.presence || DEFAULT_STATUSES
  end

  def load_settings
    raw = Setting.get('Company', @company.id, SETTING_KEY)
    case raw
    when Hash   then raw.deep_stringify_keys
    when String then (JSON.parse(raw).deep_stringify_keys rescue {})
    else              {}
    end
  end

  def bearer_token
    header = request.headers['Authorization'].to_s
    return nil unless header.start_with?('Bearer ')
    header.sub('Bearer ', '').strip
  end

  def secure_equal?(a, b)
    return false if a.blank? || b.blank?
    ActiveSupport::SecurityUtils.secure_compare(a.to_s, b.to_s)
  end

  def catalog_feed_url
    base = ENV['API_BASE_URL'] || request.base_url
    "#{base}/api/v1/meta/catalog/#{@company.id}/feed.csv?token=#{@company.meta_catalog_token}"
  end

  # One row per home, in Meta's column order. Multiple image URLs go in a single
  # comma-separated field, which CSV quoting keeps intact.
  def feed_csv(items)
    CSV.generate do |csv|
      csv << FEED_COLUMNS
      items.each do |item|
        csv << FEED_COLUMNS.map do |column|
          value = item[column.to_sym]
          value.is_a?(Array) ? value.join(',') : value
        end
      end
    end
  end

  def intake_form_url(company)
    form = company.intake_forms.respond_to?(:where) ? company.intake_forms.where(is_active: true).order(:id).first : nil
    form ||= company.intake_forms.order(:id).first rescue nil
    form&.public_url
  end

  def serialize(v, company:, base_url:)
    bedrooms  = v.try(:bedrooms)
    bathrooms = v.try(:bathrooms)

    {
      id:             "unit-#{v.id}",
      title:          build_title(v, bedrooms, bathrooms),
      description:    build_description(v, bedrooms, bathrooms),
      availability:   availability(v),
      # An empty string is truthy, so `||` left a blank condition blank and Meta
      # rejected the item for a missing required value.
      condition:      (v.try(:condition).presence || 'new').to_s,
      price:          format_price(v.try(:sale_price)),
      link:           tagged_link(base_url, v),
      image_link:     primary_image_url(v),
      additional_image_link: additional_image_urls(v),
      brand:          v.try(:make).to_s,
      inventory:      1,
      custom_label_0: custom_label_0(v),
      custom_label_1: custom_label_1(bedrooms),
      custom_label_2: custom_label_2(v.try(:sale_price)),
      custom_label_3: custom_label_3(v),
      custom_label_4: (v.try(:condition).presence || 'new').to_s
    }.compact
  end

  def build_title(v, bedrooms, bathrooms)
    parts = [v.try(:year), v.try(:make), v.try(:model)].compact.map(&:to_s).reject(&:blank?).join(' ')
    spec  = [bedrooms.present? ? "#{bedrooms}BR" : nil, bathrooms.present? ? "#{bathrooms}BA" : nil].compact.join('/')
    # No dash: this title is the product name shown in the dealer's ads and on
    # Marketplace, which is customer-facing copy.
    spec.present? ? "#{parts} (#{spec})" : parts
  end

  def build_description(v, bedrooms, bathrooms)
    bits = []
    bits << "#{v.try(:year)} #{v.try(:make)} #{v.try(:model)}".strip
    bits << "#{bedrooms} bedrooms" if bedrooms.present?
    bits << "#{bathrooms} bathrooms" if bathrooms.present?
    bits << "#{v.try(:square_feet)} sq ft" if v.try(:square_feet).present?
    bits << "Stock ##{v.try(:stock_number)}" if v.try(:stock_number).present?
    bits << "VIN #{v.try(:vin)}" if v.try(:vin).present?
    bits.reject(&:blank?).join(' · ')
  end

  # Which of Meta's required fields this item cannot fill.
  def missing_feed_fields(item)
    REQUIRED_FEED_FIELDS.reject { |field| item[field].to_s.strip.present? }
  end

  def availability(v)
    (v.try(:status).to_s == 'available') ? 'in stock' : 'out of stock'
  end

  def format_price(price)
    return nil if price.blank?
    amount = BigDecimal(price.to_s).to_s('F')
    # Meta expects "AMOUNT CURRENCY" with 2 decimals (".00 USD" per spec).
    rounded = format('%.2f', amount.to_f)
    "#{rounded} USD"
  end

  def tagged_link(base_url, v)
    return nil if base_url.blank?

    uri = URI.parse(base_url)
    existing = URI.decode_www_form(uri.query.to_s).to_h
    merged = existing.merge(
      'utm_source'   => 'facebook',
      'utm_medium'   => DEFAULT_MEDIUM,
      'utm_campaign' => DEFAULT_CAMPAIGN,
      'utm_term'     => v.try(:vin).presence || v.try(:stock_number).presence || "unit-#{v.id}"
    ).reject { |_, val| val.to_s.blank? }
    uri.query = URI.encode_www_form(merged)
    uri.to_s
  rescue URI::InvalidURIError
    nil
  end

  def all_image_urls(v)
    urls = []
    urls << v.try(:photo_url) if v.respond_to?(:photo_url) && v.photo_url.present?
    images = Array(v.try(:images))
    images.each do |img|
      url = img.is_a?(Hash) ? (img['url'] || img[:url]) : img
      urls << url if url.present?
    end
    urls.map(&:to_s).uniq
  end

  def primary_image_url(v)
    all_image_urls(v).first
  end

  def additional_image_urls(v)
    all_image_urls(v).drop(1).first(MAX_EXTRA_IMAGES)
  end

  def custom_label_0(v)
    date_in_stock = v.try(:date_in_stock) || v.try(:created_at)
    return 'new_arrival' if date_in_stock.present? && date_in_stock >= 30.days.ago
    'established'
  end

  def custom_label_1(bedrooms)
    bedrooms.present? ? "#{bedrooms}br" : nil
  end

  def custom_label_2(price)
    return nil if price.blank?
    cents = BigDecimal(price.to_s)
    return 'under_80k'    if cents < 80_000
    return '80k_to_100k'  if cents < 100_000
    return '100k_to_150k' if cents < 150_000
    '150k_plus'
  end

  def custom_label_3(v)
    city = v.try(:location_city).to_s.strip
    return nil if city.blank?
    city.downcase.gsub(/[^a-z0-9]+/, '_').gsub(/^_|_$/, '')
  end
end
