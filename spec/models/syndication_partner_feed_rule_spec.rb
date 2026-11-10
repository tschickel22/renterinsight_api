# frozen_string_literal: true

require 'rails_helper'

# The feed and the dealer Listing Partners tab share one rule for what a
# partner really receives, so the tab cannot promise homes the feed drops.
RSpec.describe SyndicationPartner, '#feed_listing_types and #feed_offer_types' do
  def partner(format:, partner_type: 'mhvillage', listing_types: nil)
    described_class.new(name: 'Site', format: format, partner_type: partner_type, listing_types: listing_types)
  end

  it 'sends manufactured homes for sale on a json or xml feed, whatever else is stored' do
    p = partner(format: 'json', listing_types: %w[manufactured_home rv apartment])
    expect(p.feed_listing_types).to eq(%w[manufactured_home])
    expect(p.feed_offer_types).to eq(%w[sale both])
    expect(p.sends_dealer_account_id?).to be(true)
  end

  it 'sends RVs for sale on the RVT feed' do
    p = partner(format: 'xml', partner_type: 'rvt')
    expect(p.feed_listing_types).to eq(%w[rv])
  end

  it 'sends nothing when the stored types and the format do not overlap' do
    expect(partner(format: 'json', listing_types: %w[rv]).feed_listing_types).to eq([])
  end

  it 'sends rentals of the stored types, or any type, on a MITS feed, without the dealer account number' do
    expect(partner(format: 'mits_xml', listing_types: %w[apartment]).feed_listing_types).to eq(%w[apartment])
    mits = partner(format: 'mits_xml')
    expect(mits.feed_listing_types).to be_nil
    expect(mits.feed_offer_types).to eq(%w[rent both])
    expect(mits.sends_dealer_account_id?).to be(false)
  end
end
