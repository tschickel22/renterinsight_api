# frozen_string_literal: true

require 'rails_helper'

# Accepts, declines and notes sent back to an appointment's invite come into
# DealerTide, go on the customer's timeline, and reach the assigned rep.
RSpec.describe Appointments::InviteReplyHandler do
  let(:company) { Company.create!(name: "Summit #{SecureRandom.hex(3)}") }
  let(:rep) do
    User.create!(email: "r-#{SecureRandom.hex(3)}@ex.com", first_name: 'Rita', last_name: 'Rep', password: 'Pass1234!',
                 company_id: company.id, role: 'sales_rep')
  end
  let(:lead) { company.leads.create!(first_name: 'Pat', last_name: 'Smith', email: 'pat@example.com') }
  let(:appointment) do
    LeadActivity.create!(lead: lead, user: rep, assigned_to: rep, activity_type: 'meeting', subject: 'Walk the Bay Port',
                         status: 'pending', priority: 'medium', start_time: 2.days.from_now, end_time: 2.days.from_now + 1.hour)
  end
  let(:token) { "appt-lead-#{appointment.id}" }

  before do
    allow(AppointmentInviteJob).to receive(:perform_later)
    allow(InboundEmail::ReplyNotifier).to receive(:notify)
  end

  def calendar_reply(email, status, comment: nil)
    lines = ['BEGIN:VCALENDAR', 'METHOD:REPLY', 'BEGIN:VEVENT', "UID:x", "ATTENDEE;PARTSTAT=#{status};CN=Someone:mailto:#{email}",
             ("COMMENT:#{comment}" if comment), 'END:VEVENT', 'END:VCALENDAR'].compact
    lines.join("\r\n")
  end

  def parsed(from:, calendar: nil, body: '', subject: 'Accepted: Walk the Bay Port')
    { from: from, to: "reply+#{token}@mail.example.com", subject: subject, body_text: body, body_html: nil,
      timestamp: Time.current, message_id: '<m1@x>', calendar: calendar }
  end

  it 'records an accept with a note, puts it on the timeline and tells the rep' do
    result = described_class.process(token: token, parsed_email: parsed(
      from: 'pat@example.com', calendar: calendar_reply('pat@example.com', 'ACCEPTED', comment: 'See you then\\, bringing my wife'),
      body: "See you then, bringing my wife\n\nPat Smith has accepted this invitation."
    ))

    expect(result[:success]).to be true
    expect(appointment.reload.customer_notices.dig('responses', 'pat@example.com', 'status')).to eq('accepted')
    comm = lead.communications.find(result[:communication_id])
    expect(comm.direction).to eq('inbound')
    expect(comm.subject).to eq('Pat Smith accepted: Walk the Bay Port')
    expect(comm.body).to include('Note: See you then, bringing my wife')
    expect(comm.body).not_to include('has accepted this invitation')
    expect(InboundEmail::ReplyNotifier).to have_received(:notify)
      .with(hash_including(entity: lead, outbound_communication: having_attributes(from_address: rep.email)))
  end

  it 'logs a plain reply to the invite email and relays it to the rep' do
    result = described_class.process(token: token, parsed_email: parsed(
      from: 'pat@example.com', subject: 'Re: Appointment: Walk the Bay Port', body: 'Can we make it 4 instead?'
    ))
    comm = lead.communications.find(result[:communication_id])
    expect(comm.body).to eq('Can we make it 4 instead?')
    expect(InboundEmail::ReplyNotifier).to have_received(:notify)
  end

  it "records the rep accepting their own copy without telling anyone" do
    described_class.process(token: token, parsed_email: parsed(from: rep.email, calendar: calendar_reply(rep.email, 'ACCEPTED')))
    expect(appointment.reload.customer_notices.dig('responses', rep.email.downcase, 'status')).to eq('accepted')
    expect(InboundEmail::ReplyNotifier).not_to have_received(:notify)
    expect(lead.communications.where("metadata->>'source' = 'calendar_reply'")).to be_empty
  end

  it 'is reached through inbound mail processing' do
    parsed_email = parsed(from: 'pat@example.com', calendar: calendar_reply('pat@example.com', 'DECLINED'))
      .merge(token: { prefix: 'reply', token: token })
    result = InboundEmail::ProcessorService.new(parsed_email).process
    expect(result[:response]).to eq('declined')
    expect(lead.communications.last.subject).to eq('Pat Smith declined: Walk the Bay Port')
  end

  it 'finds the calendar part of a real response email' do
    mail = Mail.new do
      from 'pat@example.com'
      to 'reply+appt-lead-1@mail.example.com'
      subject 'Accepted: Walk the Bay Port'
      text_part { body 'Pat Smith has accepted this invitation.' }
    end
    mail.attachments['invite.ics'] = { mime_type: 'text/calendar; method=REPLY', content: calendar_reply('pat@example.com', 'ACCEPTED') }
    data = { 'content' => Base64.encode64(mail.to_s), 'mail' => { 'destination' => ['reply+appt-lead-1@mail.example.com'] } }
    expect(InboundEmail::ParserService.new(data).parse[:calendar]).to include('METHOD:REPLY')
  end
end
