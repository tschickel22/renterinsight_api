# frozen_string_literal: true

# Public inventory feed for Meta Dynamic Ads. Meta polls this URL.
# Auth is via a company-scoped token (Authorization: Bearer <token>, or ?token=).
class Api::V1::MetaCatalogController < ApplicationController
  skip_before_action :authenticate, only: [:feed]

  MAX_EXTRA_IMAGES = 9
  DEFAULT_MEDIUM   = 'catalog_ad'
  DEFAULT_CAMPAIGN = 'rotating_inventory'

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
    vehicles = company.vehicles
                      .where(is_deleted: false, status: 'available')
                      .where.not(sale_price: nil)
                      .order(id: :asc)

    items = vehicles.map { |v| serialize(v, company: company, base_url: base_url) }

    render json: items
  end

  private

  def bearer_token
    header = request.headers['Authorization'].to_s
    return nil unless header.start_with?('Bearer ')
    header.sub('Bearer ', '').strip
  end

  def secure_equal?(a, b)
    return false if a.blank? || b.blank?
    ActiveSupport::SecurityUtils.secure_compare(a.to_s, b.to_s)
  end

  def intake_form_url(company)
    form = company.intake_forms.respond_to?(:where) ? company.intake_forms.where(active: true).order(:id).first : nil
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
      condition:      (v.try(:condition) || 'new').to_s,
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
      custom_label_4: (v.try(:condition) || 'new').to_s
    }.compact
  end

  def build_title(v, bedrooms, bathrooms)
    parts = [v.try(:year), v.try(:make), v.try(:model)].compact.map(&:to_s).reject(&:blank?).join(' ')
    spec  = [bedrooms.present? ? "#{bedrooms}BR" : nil, bathrooms.present? ? "#{bathrooms}BA" : nil].compact.join('/')
    spec.present? ? "#{parts} — #{spec}" : parts
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
