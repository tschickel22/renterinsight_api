# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Appointments::CalendarInvite do
  include ActiveJob::TestHelper

  let(:company) { Company.create!(name: "Summit #{SecureRandom.hex(3)}") }
  def make_user(first, role: 'sales_rep')
    User.create!(email: "#{first.downcase}-#{SecureRandom.hex(3)}@ex.com", first_name: first, last_name: 'Rep', password: 'Pass1234!',
                 company_id: company.id, role: role)
  end
  let(:rep) { make_user('Rita') }
  let(:admin) { make_user('Ada', role: 'company_admin') }
  let(:lead) { company.leads.create!(first_name: 'Pat', last_name: 'Smith', email: 'pat@example.com') }

  def appointment(**attrs)
    LeadActivity.create!({ lead: lead, user: admin, assigned_to: rep, activity_type: 'meeting', subject: 'Walk the Bay Port, lot 4',
                           status: 'pending', priority: 'medium', start_time: 2.days.from_now, end_time: 2.days.from_now + 1.hour }.merge(attrs))
  end

  def deliveries_to(email) = ActionMailer::Base.deliveries.select { |m| m.to.include?(email) }

  def ics_of(mail) = mail.attachments.first.decoded

  it 'invites the assigned rep and the customer with one stable UID, never the person who booked it' do
    a = appointment
    invite = described_class.new(a)
    expect(invite.recipients.map(&:first)).to eq([rep.email, 'pat@example.com'])
    expect(invite.recipients.map(&:first)).not_to include(admin.email)
  end

  it 'leaves the customer out when the appointment says not to' do
    expect(described_class.new(appointment(send_calendar_invite: false)).recipients.map(&:first)).to eq([rep.email])
  end

  it 'updates in place on a change and cancels on cancel' do
    a = nil
    expect { a = appointment }.to have_enqueued_job(AppointmentInviteJob).with('LeadActivity', anything, 'REQUEST')
    expect { a.update!(start_time: a.start_time + 1.hour, end_time: a.end_time + 1.hour) }
      .to have_enqueued_job(AppointmentInviteJob).with('LeadActivity', a.id, 'REQUEST')
    expect(a.reload.customer_notices.dig('invite', 'sequence')).to eq(1)
    expect { a.update!(status: 'cancelled') }.to have_enqueued_job(AppointmentInviteJob).with('LeadActivity', a.id, 'CANCEL')
    expect { a.update!(description: 'notes') }.not_to have_enqueued_job(AppointmentInviteJob)
  end

  it 'cancels the copy of a rep taken off the appointment' do
    a = appointment
    other = make_user('Otto')
    expect { a.update!(assigned_to: other) }
      .to have_enqueued_job(AppointmentInviteJob).with('LeadActivity', a.id, 'CANCEL', rep.id)
      .and have_enqueued_job(AppointmentInviteJob).with('LeadActivity', a.id, 'REQUEST')

    ActionMailer::Base.deliveries.clear
    AppointmentInviteJob.perform_now('LeadActivity', a.id, 'CANCEL', rep.id)
    expect(ActionMailer::Base.deliveries.map(&:to).flatten).to eq([rep.email])
    expect(ics_of(ActionMailer::Base.deliveries.last)).to include('METHOD:CANCEL')
  end

  it 'has the rep organize the customer copy and the company organize the rep copy' do
    a = appointment
    ActionMailer::Base.deliveries.clear
    expect { AppointmentInviteJob.perform_now('LeadActivity', a.id, 'REQUEST') }.to change(ActionMailer::Base.deliveries, :count).by(2)

    customer_mail = deliveries_to('pat@example.com').last
    expect(customer_mail.attachments.first.content_type).to start_with('text/calendar')
    expect(customer_mail.reply_to).to eq([rep.email])
    expect(ics_of(customer_mail)).to match(/ORGANIZER;CN=Rita Rep:mailto:#{Regexp.escape(rep.email)}/)
    expect(customer_mail.body.encoded).to include('Rita Rep')

    rep_mail = deliveries_to(rep.email).last
    expect(ics_of(rep_mail)).not_to match(/ORGANIZER[^\r\n]*#{Regexp.escape(rep.email)}/)
    expect(ics_of(rep_mail)).to include("ATTENDEE;CN=Rita Rep")
    expect(ActionMailer::Base.deliveries.map(&:to).flatten).not_to include(admin.email)

    expect(lead.communications.where("metadata->>'source' = 'calendar_invite'").count).to eq(1)
  end

  it "sends the customer copy from the rep's connected mailbox when there is one" do
    a = appointment
    conn = instance_double(UserEmailConnection, provider: 'oauth_outlook', email_address: 'rita@dealer.com', display_name: 'Rita Rep')
    allow(Appointments::RepMailbox).to receive(:connection_for).and_return(conn)
    sent = nil
    allow(Appointments::RepMailbox).to receive(:deliver) { |message, _| sent = message; true }
    ActionMailer::Base.deliveries.clear

    AppointmentInviteJob.perform_now('LeadActivity', a.id, 'REQUEST')
    expect(sent.to).to eq(['pat@example.com'])
    expect(sent.from).to eq(['rita@dealer.com'])
    expect(sent.attachments.first.decoded).to include('ORGANIZER;CN=Rita Rep:mailto:rita@dealer.com')
    expect(ActionMailer::Base.deliveries.map(&:to).flatten).to eq([rep.email])
    expect(lead.communications.last.from_address).to include('rita@dealer.com')
  end

  it 'falls back to the company address when the rep mailbox cannot send' do
    a = appointment
    conn = instance_double(UserEmailConnection, provider: 'oauth_gmail', email_address: 'rita@dealer.com', display_name: nil)
    allow(Appointments::RepMailbox).to receive(:connection_for).and_return(conn)
    allow(Appointments::RepMailbox).to receive(:deliver).and_return(false)
    ActionMailer::Base.deliveries.clear

    AppointmentInviteJob.perform_now('LeadActivity', a.id, 'REQUEST')
    expect(deliveries_to('pat@example.com').size).to eq(1)
  end

  it "invites a deal's buyer" do
    contact = company.contacts.create!(first_name: 'Dee', last_name: 'Buyer', email: 'dee@example.com')
    deal = Deal.create!(company: company, contact: contact, name: 'Dee home')
    a = DealActivity.create!(deal: deal, user: admin, assigned_to: rep, activity_type: 'meeting', subject: 'Delivery walk',
                             status: 'pending', priority: 'medium', location: 'Lot 4',
                             start_time: 2.days.from_now, end_time: 2.days.from_now + 1.hour)
    invite = described_class.new(a)
    expect(invite.recipients.map(&:first)).to eq([rep.email, 'dee@example.com'])
    expect(invite.to_ics(organizer: [rep.email, 'Rita'], attendees: [])).to include('LOCATION:Lot 4')
  end
end
