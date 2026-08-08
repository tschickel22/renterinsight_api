# frozen_string_literal: true

module Concierge
  # Everything the concierge is allowed to know about a dealer.
  #
  # Assembled once per conversation and handed to both tiers: the deterministic
  # answers read fields off it, and the model is given it as the ONLY source it
  # may answer from. A concierge that answers from general knowledge will
  # eventually tell a buyer a manufactured home needs no permit, or quote a
  # finance term this dealer does not offer, under the dealer's own logo.
  class Knowledge
    def initialize(website:)
      @website = website
      @company = website&.company
    end

    def to_h
      {
        dealer_name: dealer_name,
        phone: contact[:phone],
        email: contact[:email],
        address: contact[:address],
        hours: hours,
        pages: page_summaries,
        inventory_count: inventory_count,
        price_range: price_range,
        manufacturers: manufacturers
      }
    end

    def dealer_name
      brand['company_name'].presence || @company&.name.presence || @website&.name.to_s
    end

    def contact
      footer = @website&.site_footer.to_h
      {
        phone: (footer['phone'].presence || @company&.phone).to_s.presence,
        email: (footer['email'].presence || @company&.email).to_s.presence,
        address: address_line
      }
    end

    private

    def brand
      @brand ||= (@website&.brand.presence || {}).to_h
    end

    def address_line
      place = @website&.location&.address_line1.present? ? @website.location : @company
      return nil if place.nil? || place.try(:address_line1).blank?

      [place.try(:address_line1), place.try(:city), place.try(:state)].compact_blank.join(', ')
    end

    # Read from the dealer's own operating settings rather than invented. A
    # concierge guessing "we're open 9 to 5" sends buyers to a locked gate.
    def hours
      %w[operational_settings operational].each do |key|
        value = Setting.get('Company', @company&.id, key).to_h['business_hours']
        return value if value.present?
      end
      nil
    rescue StandardError
      nil
    end

    # Titles and first lines only. The model gets enough to say "we have a page
    # about land packages, here it is", without being handed the whole site.
    def page_summaries
      Array(@website&.website_pages&.where(is_deleted: [false, nil])&.order(:order)).first(12).map do |page|
        { title: page.title, path: page.path, summary: first_copy(page) }
      end
    end

    def first_copy(page)
      Array(page.blocks).each do |block|
        next unless block.is_a?(Hash)

        content = block['content'].is_a?(Hash) ? block['content'] : block
        text = %w[subtitle description body text].filter_map { |k| content[k] if content[k].is_a?(String) }.first
        return text.to_s.squish.truncate(200) if text.present?
      end
      nil
    end

    def sellable
      return Vehicle.none if @company.nil?

      @sellable ||= @company.vehicles.where(is_deleted: [false, nil],
                                            status: %w[available available_to_order])
    end

    def inventory_count
      sellable.count
    rescue StandardError
      0
    end

    # The actual range, so "what do you have" is answered with this dealer's
    # numbers rather than a category average.
    def price_range
      prices = sellable.where.not(sale_price: nil).where('sale_price > 0').pluck(:sale_price)
      return nil if prices.empty?

      { min: prices.min.to_i, max: prices.max.to_i }
    rescue StandardError
      nil
    end

    def manufacturers
      sellable.where.not(make: [nil, '']).distinct.pluck(:make).compact.sort.first(12)
    rescue StandardError
      []
    end
  end
end
