# frozen_string_literal: true

require 'rails_helper'

# An agreement made on a Denver evening is dated that day: the server runs in
# UTC, where it is already tomorrow.
RSpec.describe Agreements::PacketValues do
  let(:company) { Company.create!(name: "Date Co #{SecureRandom.hex(3)}") }

  it "dates the agreement in the dealer's time zone" do
    Setting.set('Company', company.id, 'operational_settings', { 'timezone' => 'America/Denver' })
    travel_to(Time.utc(2026, 10, 12, 3, 30)) do
      expect(described_class.today_for(company.reload)).to eq(Date.new(2026, 10, 11))
    end
  end

  it 'falls back to the server date for a time zone it does not know' do
    Setting.set('Company', company.id, 'operational_settings', { 'timezone' => 'Mars/Olympus' })
    travel_to(Time.utc(2026, 10, 12, 3, 30)) do
      expect(described_class.today_for(company.reload)).to eq(Date.new(2026, 10, 12))
    end
  end
end
