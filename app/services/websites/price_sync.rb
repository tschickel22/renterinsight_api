# frozen_string_literal: true

module Websites
  # Keeps a website's "Show asking prices on this website" switch (Edit
  # Website, Inventory) and the dealer's TrueBuild "What buyers see"
  # (DealerCatalogTerm#price_display, company level) in step (Tom 2026-11-11).
  #
  #   site switch off  -> What buyers see becomes hidden
  #   site switch on   -> hidden becomes full; any other choice stays
  #   What buyers see hidden      -> every website of the company: switch off
  #   What buyers see not hidden  -> every website of the company: switch on
  #
  # A synced site loses its price_list_held marker: that hold kept price list
  # prices following TrueBuild while the two settings could disagree, and now
  # they agree. featured_price_held stays: it is about Featured Homes cards,
  # which neither setting used to control, so only the dealer saving the site
  # switch (or "Show them too") lets it go.
  #
  # Only the company row's price_display counts (it is company wide, see
  # DealerCatalogTerm::COMPANY_WIDE); a manufacturer row's is never read.
  class PriceSync
    def initialize(company)
      @company = company
    end

    # After a site's switch was saved. Returns { from:, to: } when What buyers
    # see changed, else nil.
    def from_site(show_prices)
      terms = @company.dealer_catalog_terms.find_or_initialize_by(manufacturer_id: nil)
      from = terms.price_display.presence || 'hidden'
      to = if show_prices
             from == 'hidden' ? 'full' : from
           else
             'hidden'
           end
      return nil if from == to

      terms.update!(price_display: to)
      { from: from, to: to }
    end

    # After What buyers see changed. Returns how many websites changed.
    def from_terms(price_display)
      show = price_display.to_s != 'hidden'
      changed = 0
      @company.websites.where(is_deleted: [false, nil]).find_each do |website|
        settings = InventorySettings.new(website)
        stored = (website.inventory_settings || {}).to_h.deep_stringify_keys
        next if settings.show_prices? == show && stored.key?('show_prices') && !stored['price_list_held']

        stored['show_prices'] = show
        stored.delete('price_list_held')
        # A site from before the switch keeps its Featured Homes cards as they were.
        stored['featured_price_held'] = true if !stored.key?('featured_price_held') && settings.featured_price_held?
        stored['hide_rules'] ||= []
        stored['hidden_vehicle_ids'] ||= []
        website.update_columns(inventory_settings: stored, updated_at: Time.current)
        changed += 1 if settings.show_prices? != show
      end
      changed
    end

    def websites_count
      @company.websites.where(is_deleted: [false, nil]).count
    end
  end
end
