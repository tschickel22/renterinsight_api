# frozen_string_literal: true

require 'rails_helper'

# Booking, moving or cancelling an appointment texts the customer the time,
# alongside the calendar invite (E96, Tom 2026-11-06).
RSpec.describe Appointments::BookingText do
  include ActiveJob::TestHelper

  let(:company) { Company.create!(name: "Summit #{SecureRandom.hex(3)} Homes") }
  let(:rep) do
    User.create!(email: "r-#{SecureRandom.hex(3)}@ex.com", first_name: 'Rita', last_name: 'Rep', password: 'Pass1234!',
                 company_id: company.id, role: 'sales_rep')
  end
  let(:lead) { company.leads.create!(first_name: 'Pat', last_name: 'Smith', phone: '3035864420', owner_id: rep.id) }
  let(:start) { 3.days.from_now.change(hour: 16) }

  def book(**attrs)
    LeadActivity.create!({ lead: lead, user: rep, assigned_to: rep, activity_type: 'meeting', subject: 'Visit',
                           status: 'pending', priority: 'medium', start_time: start, end_time: start + 1.hour,
                           meeting_location: 'Sales office' }.merge(attrs))
  end

  before do
    allow(AppointmentInviteJob).to receive(:perform_later)
    allow(CommunicationService).to receive(:send_sms).and_return({ success: true })
  end

  it 'texts the time when booked, again when moved, and when cancelled' do
    appt = perform_enqueued_jobs { book }
    expect(CommunicationService).to have_received(:send_sms)
      .with(hash_including(to: '303-586-4420', body: a_string_including('You are set for', 'at Sales office', "Rita at #{company.name}"))).once

    perform_enqueued_jobs { appt.update!(start_time: start + 1.day, end_time: start + 1.day + 1.hour) }
    expect(CommunicationService).to have_received(:send_sms).with(hash_including(body: a_string_including('has moved to'))).once

    perform_enqueued_jobs { appt.update!(subject: 'Visit and land walk') }
    expect(CommunicationService).to have_received(:send_sms).twice # a title change is not news to the customer

    perform_enqueued_jobs { appt.update!(status: 'cancelled') }
    expect(CommunicationService).to have_received(:send_sms).with(hash_including(body: a_string_including('is cancelled'))).once
  end

  it 'stays quiet when the customer is not to be reminded, or there is no phone' do
    perform_enqueued_jobs { book(remind_customer: false) }
    lead.update!(phone: nil)
    perform_enqueued_jobs { book }
    expect(CommunicationService).not_to have_received(:send_sms)
  end
end
