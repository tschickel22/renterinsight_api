# frozen_string_literal: true

require 'rails_helper'

# Customers are reminded of appointments at the company's times, once each.
RSpec.describe Appointments::CustomerReminders do
  let(:company) { Company.create!(name: "Summit #{SecureRandom.hex(3)}") }
  let(:rep) do
    User.create!(email: "r-#{SecureRandom.hex(3)}@ex.com", first_name: 'Rita', last_name: 'Rep', password: 'Pass1234!',
                 company_id: company.id, role: 'sales_rep')
  end
  let(:lead) { company.leads.create!(first_name: 'Pat', last_name: 'Smith', email: 'pat@example.com', phone: '3035864420') }
  let(:now) { Time.zone.parse('2026-10-14 15:00') }

  def appointment(starts_in, **attrs)
    LeadActivity.create!({ lead: lead, user: rep, assigned_to: rep, activity_type: 'meeting', subject: 'Walk the Bay Port',
                           status: 'pending', priority: 'medium', start_time: now + starts_in, end_time: now + starts_in + 1.hour,
                           meeting_location: 'Sales office' }.merge(attrs))
  end

  before do
    allow(AppointmentInviteJob).to receive(:perform_later)
    allow(CommunicationService).to receive(:send_sms).and_return(true)
    allow(CommunicationService).to receive(:send_email).and_return(true)
  end

  it 'sends the day-before reminder by text and email, once' do
    a = appointment(23.hours)
    described_class.run(now: now)
    expect(CommunicationService).to have_received(:send_sms).with(hash_including(to: '303-586-4420', body: a_string_including('Reminder: your appointment', 'Sales office'))).once
    expect(CommunicationService).to have_received(:send_email).with(hash_including(to: 'pat@example.com')).once

    described_class.run(now: now + 10.minutes)
    expect(CommunicationService).to have_received(:send_sms).once
    expect(a.reload.customer_notices['reminders'].keys).to include('day_before')
  end

  it 'sends only the latest due reminder for an appointment made late' do
    a = appointment(50.minutes)
    described_class.run(now: now)
    expect(CommunicationService).to have_received(:send_sms).once
    expect(a.reload.customer_notices['reminders']['day_before']).to start_with('skipped')
    expect(a.customer_notices['reminders']['hour_before']).not_to start_with('skipped')
  end

  it 'leaves alone appointments opted out, and companies that turned it off' do
    appointment(30.minutes, remind_customer: false)
    described_class.run(now: now)
    Appointments::ReminderSettings.save(company, 'enabled' => false, 'offsets' => %w[hour_before], 'channels' => %w[sms])
    appointment(40.minutes)
    described_class.run(now: now)
    expect(CommunicationService).not_to have_received(:send_sms)
  end
end
