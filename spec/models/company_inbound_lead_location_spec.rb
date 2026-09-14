# frozen_string_literal: true

require 'rails_helper'

# Where an inbound lead lands when nothing names a location. The corporate
# location is usually an administrative shell no rep works, so a lead placed
# there is a lead nobody sees. A new company is seeded with a default "Main
# Location" and a separate corporate one.
RSpec.describe 'Inbound lead location', type: :model do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:default_location) { company.locations.find_by(is_default: true) }
  let(:corporate_location) { company.locations.find_by(is_corporate: true) }

  it 'is the default location' do
    expect(company.inbound_lead_location).to eq(default_location)
  end

  it 'falls back to a working location, never corporate, when the default is inactive' do
    default_location.update!(active: false)
    lot = Location.create!(company_id: company.id, name: 'Aurora Lot', code: "AUR-#{SecureRandom.hex(2)}", active: true)

    expect(company.inbound_lead_location).to eq(lot)
  end

  it 'is nothing rather than corporate when corporate is all that is left' do
    default_location.update!(active: false)

    expect(corporate_location).to be_present
    expect(company.inbound_lead_location).to be_nil
  end

  it 'is what an intake form uses when nothing else names a location' do
    expect(IntakeSubmission.new.send(:company_default_location_id, company.id)).to eq(default_location.id)
  end
end
