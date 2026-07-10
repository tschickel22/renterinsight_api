# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Messaging::BrandingResolver do
  let(:company) { Company.create!(name: 'Acme MH', phone: '(555) 111-2222', address_line1: '100 Corp Way', city: 'Denver', state: 'CO', zip_code: '80202') }
  let(:location) { Location.create!(company: company, name: 'Denver Showroom', phone: '(303) 555-0100', address_line1: '500 Broadway', city: 'Denver', state: 'CO', zip_code: '80203', branding_settings: { 'logo' => 'https://cdn.test/loc.png', 'primaryColor' => '#00aa55' }) }
  let(:campaign) { double('Campaign', location: nil) }
  let(:recipient) { double('Lead', location: location) }

  describe '#resolve' do
    it 'uses recipient location branding first' do
      out = described_class.new(recipient: recipient, campaign: campaign, company: company).resolve
      expect(out[:logo_url]).to eq('https://cdn.test/loc.png')
      expect(out[:primary_color]).to eq('#00aa55')
      expect(out[:name]).to eq('Denver Showroom')
      expect(out[:phone]).to eq('(303) 555-0100')
      expect(out[:address]).to include('500 Broadway')
    end

    it 'falls back to campaign location when recipient has none' do
      orphan = double('Lead', location: nil)
      camp = double('Campaign', location: location)
      out = described_class.new(recipient: orphan, campaign: camp, company: company).resolve
      expect(out[:name]).to eq('Denver Showroom')
      expect(out[:logo_url]).to eq('https://cdn.test/loc.png')
    end

    it 'falls back to company when no location on either side' do
      orphan = double('Lead', location: nil)
      camp = double('Campaign', location: nil)
      out = described_class.new(recipient: orphan, campaign: camp, company: company).resolve
      expect(out[:name]).to eq('Acme MH')
      expect(out[:phone]).to eq('(555) 111-2222')
      expect(out[:address]).to include('100 Corp Way')
      expect(out[:primary_color]).to eq('#3b82f6') # platform default
    end

    it 'gives platform default colors when nothing is configured' do
      minimal = Company.create!(name: 'Bare Co')
      orphan = double('Lead', location: nil)
      camp = double('Campaign', location: nil)
      out = described_class.new(recipient: orphan, campaign: camp, company: minimal).resolve
      expect(out[:primary_color]).to eq('#3b82f6')
      expect(out[:logo_url]).to be_nil
    end
  end
end
