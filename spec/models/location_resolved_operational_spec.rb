# frozen_string_literal: true

require 'rails_helper'

# The location Operational tab reads this. It used to raise inside (the resolver method was
# private), and the rescue hid it, so every location showed 9 to 5, seven days, as "Inherited
# from company" whatever the company's real hours were.
RSpec.describe Location, '#resolved_operational_settings' do
  let(:company) { Company.create!(name: 'Hours Co') }
  let(:location) { company.locations.create!(name: 'Main Lot', timezone: 'America/Denver') }
  let(:company_hours) do
    {
      'monday' => { 'open' => '08:00', 'close' => '16:00', 'closed' => false },
      'saturday' => { 'open' => '10:00', 'close' => '14:00', 'closed' => true }
    }
  end

  before do
    Setting.set('Company', company.id, 'operational_settings',
                { 'business_hours' => company_hours, 'delivery_radius_miles' => 75 })
  end

  it "uses the company's hours when the location has none of its own" do
    resolved = location.resolved_operational_settings
    expect(resolved['business_hours']).to eq(company_hours)
    expect(resolved['delivery_radius_miles']).to eq(75)
  end

  it "keeps the location's own hours and radius when it has them" do
    own = { 'monday' => { 'open' => '07:00', 'close' => '12:00', 'closed' => false } }
    location.update!(business_hours: own, delivery_radius_miles: 20)
    resolved = location.resolved_operational_settings
    expect(resolved['business_hours']).to eq(own)
    expect(resolved['delivery_radius_miles']).to eq(20)
  end

  it "reports the location's own time zone" do
    expect(location.resolved_operational_settings['timezone']).to eq('America/Denver')
  end
end
