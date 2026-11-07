# frozen_string_literal: true

require 'rails_helper'

# Quinn AI books visits itself (E96 phase 2): open times from the rep's hours,
# appointments, blocked time and calendar feed; booking, moving and cancelling
# in the conversation; and the rep's calendar feeds.
RSpec.describe 'Quinn AI books visits', type: :request do
  include ActiveJob::TestHelper

  let(:company) { Company.create!(name: "Summit #{SecureRandom.hex(3)} Homes", industry: 'manufactured_housing') }
  let!(:location) do
    company.locations.create!(name: 'Denver', timezone: 'America/Denver', address_line1: '100 Main St', city: 'Denver', state: 'CO',
                              business_hours: Assistant::Hours::DAYS.index_with { |d| { 'open' => '09:00', 'close' => '17:00', 'closed' => d == 'sunday' } })
  end
  let!(:rep) do
    User.create!(email: "rep-#{SecureRandom.hex(4)}@example.com", first_name: 'Jordan', last_name: 'Rep', password: 'Pass1234!',
                 company_id: company.id, role: 'company_admin', status: 'active')
  end
  let(:headers) { { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: rep.id, company_id: company.id)}", 'Content-Type' => 'application/json' } }
  let(:lead) do
    company.leads.create!(first_name: 'Tia', last_name: 'May', phone: '3035550144', email: 'tia@example.com', owner_id: rep.id,
                          sms_inquiry_consent: true, location_id: location.id)
  end
  let!(:conversation) do
    company.conversations.create!(conversable: lead, sender_number: '+17205550100', buyer_phone: '+13035550144', location_id: location.id,
                                  status: 'active', assistant_enabled: true, started_at: 1.day.ago)
  end
  let(:sent) { [] }
  # Monday 2026-11-09, 8 AM Denver.
  let(:monday_8am) { Time.find_zone('America/Denver').local(2026, 11, 9, 8, 0) }

  before do
    TenantModuleOverride.create!(company: company, module_key: 'marketing.lead_assistant', is_enabled: true)
    Assistant::Settings.for(company).update!('enabled' => true)
    TwilioAccount.create!(company: company, phone_number: '+17205550100', phone_number_sid: "PN#{SecureRandom.hex(8)}", status: 'active')
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('TWILIO_AUTH_TOKEN').and_return(nil)
    allow(ENV).to receive(:[]).with('TWILIO_PHONE_NUMBER').and_return(nil)
    calls = sent
    allow_any_instance_of(Providers::Sms::TwilioProvider).to receive(:send_message) do |_p, **args|
      calls << args
      { success: true, external_id: "SM#{SecureRandom.hex(8)}", provider: 'twilio' }
    end
  end

  def brain_says(reply, book_slot: nil, cancel_visit: false)
    allow_any_instance_of(Assistant::Brain).to receive(:call).and_return(
      Assistant::Brain::Result.new(reply: reply, qualification: {}, contact: {}, resend_invite: false, photo_home_id: nil, question: nil,
                                   question_answered: false, question_topic: nil, handoff: false, handoff_reason: nil, summary: '',
                                   usage: {}, book_slot: book_slot, cancel_visit: cancel_visit)
    )
  end

  def buyer_texts(body)
    comm = Communication.create!(communicable: lead, company_id: company.id, channel: 'sms', direction: 'inbound', status: 'delivered',
                                 body: body, to_address: '+17205550100', from_address: '+13035550144', conversation_id: conversation.id)
    Assistant::Inbound.received(conversation, comm)
  end

  it 'offers open times inside the rep\'s hours, a morning and an afternoon, around their visits and blocked time' do
    travel_to(monday_8am) do
      LeadActivity.create!(lead_id: lead.id, user_id: rep.id, assigned_to_id: rep.id, activity_type: 'meeting', subject: 'Other visit',
                           start_time: monday_8am.change(hour: 10), end_time: monday_8am.change(hour: 11), status: 'pending',
                           send_calendar_invite: false, remind_customer: false)
      CalendarBusyBlock.create!(company: company, user: rep, starts_at: monday_8am.change(hour: 14), ends_at: monday_8am.change(hour: 17))
      slots = Assistant::Availability.new(company: company, user: rep, location: location).slots(days: 1)
      monday = slots.select { |s| s.starts_at.to_date == monday_8am.to_date }.map { |s| s.starts_at.strftime('%H:%M') }
      expect(monday).to eq(%w[11:00 13:00])
      expect(slots.first.label).to eq('Mon Nov 9 at 11:00 AM')
    end
  end

  it 'books the time the buyer picks, confirms it itself, and keeps the conversation' do
    travel_to(monday_8am) do
      slot = Assistant::Booking.new(conversation).slots.first
      brain_says('Perfect.', book_slot: slot.id)
      buyer_texts('The first one works')
      expect(enqueued_jobs.map { |j| j['job_class'] }).to include('AssistantReplyJob')
      perform_enqueued_jobs(only: AssistantReplyJob)

      visit = LeadActivity.where(lead_id: lead.id, activity_type: 'meeting').last
      expect(visit).to have_attributes(start_time: slot.starts_at, assigned_to_id: rep.id, meeting_location: '100 Main St, Denver, CO')
      expect(visit.metadata).to include('booked_by' => 'quinn_ai')
      expect(sent.last[:body]).to include("Perfect. You are set for #{slot.label} at 100 Main St, Denver, CO with Jordan")
      expect(enqueued_jobs.map { |j| j['job_class'] }).not_to include('AppointmentBookingTextJob')
      expect(conversation.reload).to have_attributes(status: 'active', next_follow_up_at: nil)
    end
  end

  it 'offers the next times when the picked one was taken, and moves or cancels a booked visit' do
    travel_to(monday_8am) do
      booking = Assistant::Booking.new(conversation)
      slot = booking.slots.first
      CalendarBusyBlock.create!(company: company, user: rep, starts_at: slot.starts_at, ends_at: slot.ends_at)
      outcome = Assistant::Booking.new(conversation).book!(slot.id)
      expect(outcome.ok).to be(true) # the fresh list no longer has it under that id, so it books the new T1
      first = LeadActivity.last
      expect(first.start_time).not_to eq(slot.starts_at)

      later = Assistant::Booking.new(conversation)
      new_slot = later.slots.last
      moved = later.book!(new_slot.id)
      expect(moved.kind).to eq('moved')
      expect(first.reload.start_time).to eq(new_slot.starts_at)

      gone = Assistant::Booking.new(conversation).cancel!
      expect(gone.kind).to eq('cancelled')
      expect(first.reload.status).to eq('cancelled')
      expect(gone.text).to include('is cancelled')
    end
  end

  it 'says the time went and offers others when it is no longer open' do
    travel_to(monday_8am) do
      booking = Assistant::Booking.new(conversation)
      slot = booking.slots.first
      CalendarBusyBlock.create!(company: company, user: rep, starts_at: slot.starts_at, ends_at: slot.ends_at)
      outcome = booking.book!(slot.id)
      expect(outcome.ok).to be(false)
      expect(outcome.text).to start_with('Sorry, that time was just taken. I can do')
    end
  end

  it 'gives each rep a private calendar link and reads busy times from their own calendar' do
    get '/api/v1/my_availability', headers: headers
    body = JSON.parse(response.body)
    expect(body['feed_url']).to match(%r{/calendar/[\w-]+\.ics\z})

    LeadActivity.create!(lead_id: lead.id, user_id: rep.id, assigned_to_id: rep.id, activity_type: 'meeting', subject: 'Visit: Tia May',
                         start_time: 2.days.from_now, end_time: 2.days.from_now + 1.hour, status: 'pending', send_calendar_invite: false, remind_customer: false)
    get URI(body['feed_url']).path
    expect(response.media_type).to eq('text/calendar')
    expect(response.body).to include('SUMMARY:Visit: Tia May').and include('BEGIN:VCALENDAR')

    ics = <<~ICS
      BEGIN:VCALENDAR
      BEGIN:VEVENT
      DTSTART;TZID=America/Denver:20261109T090000
      DTEND;TZID=America/Denver:20261109T100000
      RRULE:FREQ=WEEKLY;BYDAY=MO,WE
      SUMMARY:Sales meeting
      END:VEVENT
      BEGIN:VEVENT
      DTSTART:20261110T200000Z
      DTEND:20261110T210000Z
      TRANSP:TRANSPARENT
      END:VEVENT
      END:VCALENDAR
    ICS
    reader = CalendarFeeds::BusyReader.new(rep, body: ics)
    times = reader.busy_times(monday_8am, monday_8am + 7.days).map { |(s, _)| s.in_time_zone('America/Denver').strftime('%a %H:%M') }
    expect(times).to eq(['Mon 09:00', 'Wed 09:00'])

    patch '/api/v1/my_availability', headers: headers,
                                     params: { availability: { working_hours: { 'monday' => { 'open' => '10:00', 'close' => '16:00' } } } }.to_json
    expect(rep.reload.working_hours['monday']).to eq('open' => '10:00', 'close' => '16:00', 'closed' => false)

    post '/api/v1/my_availability/blocks', headers: headers,
                                           params: { block: { starts_at: 3.days.from_now.iso8601, ends_at: (3.days.from_now + 2.hours).iso8601, note: 'Dentist' } }.to_json
    expect(JSON.parse(response.body)['blocks'].first).to include('note' => 'Dentist')
  end
end
