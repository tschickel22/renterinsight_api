# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Websites::InventoryCardSettings do
  def company(**overrides)
    defaults = {
      default_layout: nil, items_per_page: nil, show_pricing: nil, show_filters: nil,
      show_contact_button: nil, contact_button_text: nil, public_statuses: nil
    }
    instance_double(Company, **defaults.merge(overrides))
  end

  it 'returns an empty hash for no company rather than a misleading default card' do
    expect(described_class.for(nil)).to eq({})
  end

  describe 'defaults' do
    subject(:card) { described_class.for(company) }

    # Opt-out, matching the public inventory embed: a dealer who has never
    # opened the settings screen still gets a usable card.
    it 'shows pricing, filters and the contact button' do
      expect(card).to include(showPricing: true, showFilters: true, showContactButton: true)
    end

    it 'defaults to a 12-up grid' do
      expect(card).to include(layout: 'grid', perPage: 12)
    end

    it 'sends no status allowlist so the embed applies its own default' do
      expect(card[:statuses]).to be_nil
    end
  end

  describe 'dealer configuration' do
    it 'carries the configured layout and page size' do
      card = described_class.for(company(default_layout: 'list', items_per_page: 24))

      expect(card).to include(layout: 'list', perPage: 24)
    end

    it 'honours an explicit false' do
      card = described_class.for(company(show_pricing: false, show_filters: false))

      expect(card).to include(showPricing: false, showFilters: false)
    end

    it 'carries custom contact button text' do
      expect(described_class.for(company(contact_button_text: 'Check Availability'))[:contactButtonText])
        .to eq('Check Availability')
    end

    it 'passes through a status allowlist' do
      expect(described_class.for(company(public_statuses: %w[available on_order]))[:statuses])
        .to eq(%w[available on_order])
    end

    # An empty array must not become an allowlist matching nothing.
    it 'treats an empty status list as unset' do
      expect(described_class.for(company(public_statuses: []))[:statuses]).to be_nil
    end
  end

  describe 'guards' do
    it 'ignores an unrecognised layout' do
      expect(described_class.for(company(default_layout: 'masonry'))[:layout]).to eq('grid')
    end

    # A dealer who typed 500 would render a page that never finishes painting
    # on a phone.
    it 'clamps an absurd page size' do
      expect(described_class.for(company(items_per_page: 500))[:perPage]).to eq(described_class::MAX_PER_PAGE)
    end

    it 'ignores a zero or negative page size' do
      expect(described_class.for(company(items_per_page: 0))[:perPage]).to eq(12)
      expect(described_class.for(company(items_per_page: -5))[:perPage]).to eq(12)
    end
  end
end
