# frozen_string_literal: true

require 'rails_helper'

# The Dealer Logo agreement field prints the location's logo, else the
# company's, and never the platform's.
RSpec.describe Agreements::DealerLogo do
  let(:company)  { Company.create!(name: "Logo Co #{SecureRandom.hex(3)}") }
  let(:location) { company.locations.create!(name: 'Showroom', timezone: 'America/Denver') }
  let(:company_logo)  { 'https://assets.example.com/uploads/1/logos/company/co.png' }
  let(:location_logo) { 'https://assets.example.com/uploads/1/logos/location/loc.png' }

  before { Setting.set('Platform', 0, 'branding', { 'logo' => 'https://assets.example.com/platform.png' }) }

  it "uses the location's logo when it has one" do
    Setting.set('Company', company.id, 'branding', { 'logo' => company_logo })
    Setting.set('Location', location.id, 'branding', { 'logo' => location_logo })

    expect(described_class.url(company, location_id: location.id)).to eq(location_logo)
  end

  it "falls back to the company's logo when the location has none" do
    Setting.set('Company', company.id, 'branding', { 'logo' => company_logo })
    Setting.set('Location', location.id, 'branding', { 'logo' => nil })

    expect(described_class.url(company, location_id: location.id)).to eq(company_logo)
    expect(described_class.url(company)).to eq(company_logo)
  end

  it 'never prints the platform logo' do
    expect(described_class.url(company, location_id: location.id)).to be_nil
  end

  it "ignores another company's location" do
    other = Company.create!(name: "Other #{SecureRandom.hex(3)}")
    other_location = other.locations.create!(name: 'Theirs', timezone: 'UTC')
    Setting.set('Location', other_location.id, 'branding', { 'logo' => location_logo })
    Setting.set('Company', company.id, 'branding', { 'logo' => company_logo })

    expect(described_class.url(company, location_id: other_location.id)).to eq(company_logo)
  end

  it 'makes an old API-relative logo path absolute' do
    Setting.set('Company', company.id, 'branding', { 'logo' => '/uploads/1/logos/company/old.png' })

    expect(described_class.url(company)).to end_with('/uploads/1/logos/company/old.png')
    expect(described_class.url(company)).to start_with('http')
  end

  it "uses the agreement's location, else its deal's" do
    Setting.set('Company', company.id, 'branding', { 'logo' => company_logo })
    Setting.set('Location', location.id, 'branding', { 'logo' => location_logo })
    agreement = instance_double(Agreement, company: company, location_id: nil, deal_id: nil)
    deal = instance_double(Deal, location_id: location.id)

    expect(described_class.for_agreement(agreement, deal: deal)).to eq(location_logo)
    expect(described_class.for_agreement(agreement)).to eq(company_logo)
  end
end
