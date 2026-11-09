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

      notices = Notification.where(notification_type: 'assistant_booking', recipient: rep).order(:id)
      expect(notices.map(&:title)).to eq(['Quinn AI Booked a Visit', 'Quinn AI Moved a Visit', 'Quinn AI Cancelled a Visit'])
      expect(notices.first.message).to include('Tia May')
      expect(notices.first.action_url).to eq("/inbox?c=#{conversation.id}")
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

  it 'texts kindly with two new times an hour after a rep marks a no-show, taking the conversation back' do
    travel_to(monday_8am) do
      visit = LeadActivity.create!(lead_id: lead.id, user_id: rep.id, assigned_to_id: rep.id, activity_type: 'meeting', subject: 'Visit',
                                   start_time: monday_8am.change(hour: 7), end_time: monday_8am.change(hour: 8), status: 'pending',
                                   send_calendar_invite: false, remind_customer: false)
      conversation.update!(status: 'handed_off', handoff_reason: 'rep_replied')
      expect { visit.update!(status: 'no_show') }.to have_enqueued_job(AssistantNoShowJob).with('LeadActivity', visit.id)

      brain_says('No problem at all, things come up. Would Tuesday at 10 AM or 2 PM work instead?')
      AssistantNoShowJob.perform_now('LeadActivity', visit.id)
      expect(sent.last[:body]).to include('No problem at all')
      expect(conversation.reload).to have_attributes(status: 'active', assistant_enabled: true)
      # Then Quinn's follow-ups run from today, aimed at a new visit.
      expect(conversation.follow_up_count).to eq(0)
      expect(conversation.next_follow_up_at).to be_within(1.minute).of(1.day.from_now)
      expect(Assistant::Appointments.last_missed(lead)).to eq(visit)
    end
  end

  it 'tells follow-ups about the missed visit until a new one is booked' do
    travel_to(monday_8am) do
      visit = LeadActivity.create!(lead_id: lead.id, user_id: rep.id, assigned_to_id: rep.id, activity_type: 'meeting', subject: 'Visit',
                                   start_time: 1.day.ago, end_time: 1.day.ago + 1.hour, status: 'no_show',
                                   send_calendar_invite: false, remind_customer: false)
      seen = []
      allow(Assistant::Brain).to receive(:new).and_wrap_original { |m, **kw| seen << kw[:missed_visit]; m.call(**kw) }
      allow_any_instance_of(Assistant::Brain).to receive(:call).and_return(
        Assistant::Brain::Result.new(reply: 'Still happy to find you a time. Would Tuesday at 10 AM work?', qualification: {}, contact: {},
                                     usage: {}, handoff: false)
      )
      conversation.update_columns(follow_up_anchor_at: 2.days.ago, follow_up_count: 0, next_follow_up_at: 1.minute.ago)
      Assistant::FollowUp.new(conversation).run!
      expect(seen.compact.first).to include(Appointments::TimeText.for(visit, company).split(' at ').first)

      LeadActivity.create!(lead_id: lead.id, user_id: rep.id, assigned_to_id: rep.id, activity_type: 'meeting', subject: 'Visit',
                           start_time: 3.days.from_now, end_time: 3.days.from_now + 1.hour, status: 'pending',
                           send_calendar_invite: false, remind_customer: false)
      expect(Assistant::Appointments.last_missed(lead)).to be_nil
    end
  end

  it 'asks the rep 30 minutes after a visit started whether the buyer came, once' do
    travel_to(monday_8am) do
      visit = LeadActivity.create!(lead_id: lead.id, user_id: rep.id, assigned_to_id: rep.id, activity_type: 'meeting', subject: 'Visit',
                                   start_time: 40.minutes.ago, end_time: 20.minutes.from_now, status: 'pending',
                                   send_calendar_invite: false, remind_customer: false)
      LeadActivity.create!(lead_id: lead.id, user_id: rep.id, assigned_to_id: rep.id, activity_type: 'meeting', subject: 'Later',
                           start_time: 10.minutes.ago, end_time: 50.minutes.from_now, status: 'pending',
                           send_calendar_invite: false, remind_customer: false)
      VisitCheckInJob.perform_now
      VisitCheckInJob.perform_now
      notices = Notification.where(notification_type: 'visit_check_in', recipient: rep)
      expect(notices.count).to eq(1)
      expect(notices.first.message).to include('Did Tia May make the').and include('Quinn AI will text them new times')
      expect(notices.first.action_url).to eq("/crm/leads/#{lead.id}?tab=activities")
      expect(visit.reload.metadata['check_in_asked_at']).to be_present

      Assistant::Settings.for(company).update!('enabled' => false)
      other = LeadActivity.create!(lead_id: lead.id, user_id: rep.id, assigned_to_id: rep.id, activity_type: 'meeting', subject: 'Visit 2',
                                   start_time: 50.minutes.ago, end_time: 10.minutes.ago, status: 'pending',
                                   send_calendar_invite: false, remind_customer: false)
      VisitCheckInJob.perform_now
      expect(notices.count).to eq(1) # no Quinn and not booked by Quinn: not asked
      expect(other.reload.metadata.to_h['check_in_asked_at']).to be_nil
    end
  end
end
