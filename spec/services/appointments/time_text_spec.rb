# frozen_string_literal: true

require 'rails_helper'

# Appointment times read in the customer's location's zone, not the company
# default (Eastern), so a Denver visit at 4 PM is texted as 4 PM.
RSpec.describe Appointments::TimeText do
  let(:company) { Company.create!(name: "Co #{SecureRandom.hex(3)}") }
  let(:rep) do
    User.create!(email: "r-#{SecureRandom.hex(3)}@ex.com", first_name: 'R', last_name: 'R', password: 'Pass1234!',
                 company_id: company.id, role: 'sales_rep')
  end
  let(:denver) { company.locations.create!(name: 'Denver Showroom', timezone: 'America/Denver') }
  let(:start) { Time.utc(2026, 11, 10, 23, 0) } # 4:00 PM in Denver, 6:00 PM in New York

  def appt(lead)
    allow(AppointmentInviteJob).to receive(:perform_later)
    allow(AppointmentBookingTextJob).to receive(:perform_later)
    LeadActivity.create!(lead: lead, user: rep, activity_type: 'meeting', subject: 'Visit', status: 'pending', priority: 'medium',
                         start_time: start, end_time: start + 1.hour)
  end

  it "uses the lead's location's time zone" do
    lead = company.leads.create!(first_name: 'P', last_name: 'S', location_id: denver.id)
    expect(described_class.for(appt(lead), company)).to eq('Tue Nov 10 at 4:00 PM')
  end

  it "falls back to the company's zone without a location" do
    lead = company.leads.create!(first_name: 'P', last_name: 'S', location_id: nil)
    expect(described_class.for(appt(lead), company)).to eq('Tue Nov 10 at 6:00 PM')
  end
end
