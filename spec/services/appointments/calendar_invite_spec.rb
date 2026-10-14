# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Appointments::CalendarInvite do
  include ActiveJob::TestHelper

  let(:company) { Company.create!(name: "Summit #{SecureRandom.hex(3)}") }
  let(:rep) do
    User.create!(email: "r-#{SecureRandom.hex(3)}@ex.com", first_name: 'Rita', last_name: 'Rep', password: 'Pass1234!',
                 company_id: company.id, role: 'sales_rep')
  end
  let(:lead) { company.leads.create!(first_name: 'Pat', last_name: 'Smith', email: 'pat@example.com') }

  def appointment(**attrs)
    LeadActivity.create!({ lead: lead, user: rep, assigned_to: rep, activity_type: 'meeting', subject: 'Walk the Bay Port, lot 4',
                           status: 'pending', priority: 'medium', start_time: 2.days.from_now, end_time: 2.days.from_now + 1.hour }.merge(attrs))
  end

  it 'invites the rep and the customer with one stable UID' do
    a = appointment
    invite = described_class.new(a)
    expect(invite.recipients.map(&:first)).to eq([rep.email, 'pat@example.com'])
    ics = invite.to_ics
    expect(ics).to include('METHOD:REQUEST', "UID:#{invite.uid}", 'SEQUENCE:0', 'SUMMARY:Walk the Bay Port\\, lot 4', "mailto:#{rep.email}")
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

  it 'emails the invite as a calendar attachment and logs the customer copy' do
    a = appointment
    expect { AppointmentInviteJob.perform_now('LeadActivity', a.id, 'REQUEST') }.to change(ActionMailer::Base.deliveries, :count).by(2)
    mail = ActionMailer::Base.deliveries.last
    expect(mail.attachments.first.content_type).to start_with('text/calendar')
    expect(lead.communications.where("metadata->>'source' = 'calendar_invite'").count).to eq(1)
  end
end
