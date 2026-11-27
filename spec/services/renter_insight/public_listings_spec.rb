# frozen_string_literal: true

require 'rails_helper'

RSpec.describe RenterInsight::PublicListings do
  # What Renter Insight's search answers with, private company record included.
  let(:raw) do
    {
      'unit_listings' => [
        {
          'hash_id' => '54208600', 'status' => 'active', 'rent' => '1400.0', 'security_deposit' => '400.0',
          'lease_term' => 12, 'available_on' => '2020-10-01', 'description' => "A charming studio.\n",
          'street_and_unit' => '2124 California Ave SW, Unit #203',
          'metadata_description' => 'Beds: Studio | Baths: 1.0 | SQFT: 450 | Rent: $1,400/mo | Available: Now',
          'photo_url' => 'https://app.renterinsight.com/rails/active_storage/blobs/redirect/x/a.jpeg'
        },
        {
          'hash_id' => '1', 'status' => 'active', 'rent' => '1950', 'available_on' => '2999-01-15',
          'street_and_unit' => '2124 California Ave SW, Unit #301',
          'metadata_description' => 'Beds: 2 | Baths: 1.0 | SQFT: 1,050 | Rent: $1,950/mo',
          'photo_url' => 'http://insecure.test/b.jpg'
        },
        { 'hash_id' => '2', 'status' => 'inactive', 'rent' => '900' }
      ],
      'properties' => [{ 'name' => 'The James Apartments', 'street' => '2124 California Ave SW',
                         'city' => 'Seattle', 'state' => 'WA', 'zip' => '98116', 'owner_id' => 9 }],
      'company' => { 'bank_accounts' => [{ 'account_number' => '0000000000', 'routing_number' => '000000000' }],
                     'tax_id' => '00-0000000' }
    }
  end

  def call_with(raw)
    client = described_class.new('15914382')
    allow(client).to receive(:request_search).and_return(raw)
    client.call
  end

  it 'returns only active units, with specs read from the meta description' do
    result = call_with(raw)

    expect(result[:listings].map { |l| l[:id] }).to eq(%w[54208600 1])
    studio = result[:listings].first
    expect(studio).to include(title: 'Studio, Unit 203', unit: 'Unit 203', beds: 0, beds_label: 'Studio',
                              baths: 1, sqft: 450, rent: 1400, deposit: 400, lease_term_months: 12,
                              available_on: '2020-10-01', available_now: true)
    two = result[:listings].last
    expect(two).to include(beds: 2, beds_label: '2 Bedroom', sqft: 1050, available_now: false)
  end

  it 'never lets the company record or unknown property fields through' do
    json = call_with(raw).to_json

    expect(json).not_to include('bank_accounts', 'account_number', 'routing_number', 'tax_id', 'owner_id')
    expect(call_with(raw)[:property]).to eq(name: 'The James Apartments', street: '2124 California Ave SW',
                                             city: 'Seattle', state: 'WA', zip: '98116')
  end

  it 'drops photos that are not https' do
    expect(call_with(raw)[:listings].last[:photo_url]).to be_nil
  end

  it 'returns nil when Renter Insight cannot be read' do
    expect(call_with(nil)).to be_nil

    client = described_class.new('15914382')
    allow(client).to receive(:request_search).and_raise(Timeout::Error)
    expect(client.call).to be_nil
  end

  it 'refuses ids that are not Renter Insight listing ids' do
    expect(described_class.fetch('../admin')).to be_nil
    expect(described_class.valid_id?('15914382')).to be(true)
  end
end
