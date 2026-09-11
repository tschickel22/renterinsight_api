# frozen_string_literal: true

require 'rails_helper'

# A walkthrough is among the most persuasive things on a listing, and until now
# a shopper had no way to ask for one — nor did the feed publish the Matterport
# link at all. Three columns hold a tour on vehicles (matterport_url,
# virtual_tour_url and the legacy virtual_tour) and only the middle one was
# ever exposed, so a home with a full walkthrough looked like a home with none.
RSpec.describe 'Public inventory tours', type: :request do
  let(:company) do
    create(:company).tap do |c|
      c.update!(public_inventory_token: SecureRandom.hex(8),
                public_inventory_settings: { 'public_inventory_enabled' => true })
    end
  end

  def home(attrs = {})
    Vehicle.create!({ company: company, year: 2025, make: 'Clayton', model: 'Tide',
                      vin: "VIN#{SecureRandom.hex(6).upcase}", status: 'available',
                      is_deleted: false, images: ['https://cdn.example.com/a.jpg'] }.merge(attrs))
  end

  def listing(params = {})
    get '/public/inventory', params: { token: company.public_inventory_token,
                                       company_id: company.id }.merge(params)
    JSON.parse(response.body)
  end

  describe 'the feed' do
    it 'publishes a Matterport walkthrough, which it never used to' do
      home(matterport_url: 'https://my.matterport.com/show/?m=abc')

      item = listing['items'].first

      expect(item['has_3d_tour']).to be true
      expect(item['tour_url']).to eq('https://my.matterport.com/show/?m=abc')
    end

    # Which link a dealer would pick if asked: a walkthrough over a 360 embed,
    # and either over a column left behind by an old import.
    it 'prefers the walkthrough when a home has both' do
      home(matterport_url: 'https://my.matterport.com/show/?m=abc',
           virtual_tour_url: 'https://spin.example.com/360')

      expect(listing['items'].first['tour_url']).to include('matterport')
    end

    it 'still publishes a 360 tour when that is all there is' do
      home(virtual_tour_url: 'https://spin.example.com/360')

      expect(listing['items'].first['tour_url']).to eq('https://spin.example.com/360')
    end

    it 'says so plainly when a home has no tour' do
      home

      expect(listing['items'].first['has_3d_tour']).to be false
      expect(listing['items'].first['tour_url']).to be_nil
    end
  end

  describe 'filtering' do
    before do
      home(matterport_url: 'https://my.matterport.com/show/?m=abc', model: 'Walkthrough')
      home(virtual_tour_url: 'https://spin.example.com/360', model: 'Spin')
      home(model: 'Nothing')
    end

    it 'returns only homes you can walk through' do
      models = listing(has_3d_tour: 'true')['items'].map { |i| i['model'] }

      expect(models).to match_array(%w[Walkthrough Spin])
    end

    it 'counts them honestly, so the pager matches what is shown' do
      data = listing(has_3d_tour: 'true')

      expect(data.dig('meta', 'total') || data['total']).to eq(2)
    end

    it 'leaves the listing alone when the filter is off' do
      expect(listing['items'].size).to eq(3)
    end

    it 'ignores an empty string rather than filtering everything out' do
      expect(listing(has_3d_tour: '')['items'].size).to eq(3)
    end
  end
end
