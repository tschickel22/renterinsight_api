# frozen_string_literal: true

require 'rails_helper'

# The dealer's day, for dates set outside a signed-in dealer request. On UTC,
# a portal invoice at 7 PM in Denver was dated tomorrow.
RSpec.describe Company, '#today' do
  let(:company) { create(:company, industry: 'manufactured_housing') }

  it "is the dealer's calendar day, not UTC's" do
    Setting.set('Company', company.id, 'operational_settings', { 'timezone' => 'America/Denver' })
    travel_to(Time.utc(2026, 11, 11, 2, 0)) { expect(company.reload.today).to eq(Date.new(2026, 11, 10)) }
  end
end
