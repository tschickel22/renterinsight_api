# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Messaging::ContactResolver do
  let(:company) { Company.create!(name: 'Acme MH', phone: '(555) 111-2222', email: 'info@acme.test', address_line1: '100 Corp Way') }
  let(:location) { Location.create!(company: company, name: 'Denver Showroom', phone: '(303) 555-0100', email: 'denver@acme.test', address_line1: '500 Broadway') }
  let(:campaign) { double('Campaign', location: location) }

  describe '#resolve' do
    it 'renders rep-first when sender_user is present' do
      user = double('User', first_name: 'Jacob', last_name: 'Andries', title: 'Sales Manager', email: 'jacob@acme.test', phone: '(303) 555-0155', typed_signature: nil, booking_url: 'https://cal.test/jacob', primary_location: location, location: nil, locations: nil)
      out = described_class.new(sender_user: user, campaign: campaign, company: company).resolve
      expect(out[:name]).to eq('Jacob Andries')
      expect(out[:title]).to eq('Sales Manager')
      expect(out[:email]).to eq('jacob@acme.test')
      expect(out[:phone]).to eq('(303) 555-0155')
      expect(out[:booking_url]).to eq('https://cal.test/jacob')
      expect(out[:location_name]).to eq('Denver Showroom')
    end

    it 'fills missing rep fields from location' do
      user = double('User', first_name: 'Jacob', last_name: 'Andries', title: nil, email: 'jacob@acme.test', phone: nil, typed_signature: nil, booking_url: nil, primary_location: location, location: nil, locations: nil)
      out = described_class.new(sender_user: user, campaign: campaign, company: company).resolve
      expect(out[:phone]).to eq('(303) 555-0100') # falls back to location
      expect(out[:email]).to eq('jacob@acme.test') # rep still wins
    end

    it 'falls all the way through to company for Location-type sends (no sender_user)' do
      camp = double('Campaign', location: location)
      out = described_class.new(sender_user: nil, campaign: camp, company: company).resolve
      expect(out[:name]).to eq('Denver Showroom')
      expect(out[:phone]).to eq('(303) 555-0100')
    end

    it 'falls to company when no sender_user and no location' do
      camp = double('Campaign', location: nil)
      out = described_class.new(sender_user: nil, campaign: camp, company: company).resolve
      expect(out[:name]).to eq('Acme MH')
      expect(out[:phone]).to eq('(555) 111-2222')
      expect(out[:email]).to eq('info@acme.test')
    end
  end
end
