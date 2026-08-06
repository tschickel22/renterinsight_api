# frozen_string_literal: true

module Websites
  # How a company has chosen to present its inventory listings.
  #
  # These values already existed on Company#public_inventory_settings and were
  # already honoured by the public inventory embed, but nothing carried them to
  # a website's inventory block. The block fell back to whatever the template
  # author happened to type — so a dealer who had set list layout, 24 per page
  # and hidden pricing saw a 6-up grid with prices on every design we showed
  # them, and again on the site once it was built.
  #
  # Emitted alongside the embed token so every inventory surface (design
  # showcase, shared demo preview, live site) renders the same card the dealer
  # configured.
  #
  # Keys are camelCase: the renderer consumes them directly.
  class InventoryCardSettings
    DEFAULT_CONTACT_TEXT = 'Request Info'
    DEFAULT_PER_PAGE = 12
    MAX_PER_PAGE = 48

    def self.for(company)
      new(company).to_h
    end

    def initialize(company)
      @company = company
    end

    def to_h
      return {} if @company.nil?

      {
        layout: layout,
        perPage: per_page,
        # Opt-out, matching the public embed: an untouched setting shows prices.
        showPricing: setting(:show_pricing) != false,
        showFilters: setting(:show_filters) != false,
        showContactButton: setting(:show_contact_button) != false,
        contactButtonText: setting(:contact_button_text).presence || DEFAULT_CONTACT_TEXT,
        # Empty means "whatever the embed defaults to" rather than "show none",
        # so an unset value must not be sent as an empty allowlist.
        statuses: statuses
      }
    end

    private

    def setting(key)
      @company.try(key)
    end

    def layout
      value = setting(:default_layout).to_s.downcase
      %w[grid list].include?(value) ? value : 'grid'
    end

    # Clamped: a dealer who typed 500 would render a listing page that never
    # finishes painting on a phone.
    def per_page
      value = setting(:items_per_page).to_i
      return DEFAULT_PER_PAGE unless value.positive?

      [value, MAX_PER_PAGE].min
    end

    def statuses
      Array(setting(:public_statuses)).map(&:to_s).reject(&:blank?).presence
    end
  end
end
