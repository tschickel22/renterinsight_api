# frozen_string_literal: true

require 'rails_helper'

# An appointment given to someone else tells them; the creator's own does not.
RSpec.describe NotifiesActivityAssignee do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  def user(name)
    User.create!(email: "#{name}-#{SecureRandom.hex(3)}@ex.com", first_name: name, last_name: 'Rep', password: 'Pass1234!',
                 company_id: company.id, role: 'sales_rep')
  end
  let(:sam) { user('Sam') }
  let(:ana) { user('Ana') }
  let(:lead) { company.leads.create!(first_name: 'Pat', last_name: 'Smith', email: 'pat@example.com') }

  def appointment(assigned_to:)
    LeadActivity.create!(lead: lead, user: sam, assigned_to: assigned_to, activity_type: 'meeting', subject: 'Walk the Bay Port',
                         status: 'pending', priority: 'medium', start_time: 1.day.from_now.change(hour: 15), end_time: 1.day.from_now.change(hour: 16))
  end

  before { Current.user = sam }
  after { Current.user = nil }

  it 'tells someone else they have an appointment, with whom and when' do
    appointment(assigned_to: ana)
    note = Notification.find_by(recipient: ana, notification_type: 'appointment_assigned')
    expect(note).to be_present
    expect(note.message).to include('Sam Rep set an appointment with Pat Smith for you', 'Walk the Bay Port')
    expect(note.action_url).to eq("/crm/leads/#{lead.id}?tab=activities")
  end

  it 'does not tell the creator about their own' do
    appointment(assigned_to: sam)
    expect(Notification.where(notification_type: 'appointment_assigned')).to be_empty
  end

  it 'tells the new person when it is reassigned, once' do
    a = appointment(assigned_to: sam)
    a.update!(assigned_to: ana)
    expect(Notification.where(recipient: ana, notification_type: 'appointment_assigned').count).to eq(1)
    a.update!(subject: 'Walk the Bay Port again')
    expect(Notification.where(recipient: ana, notification_type: 'appointment_assigned').count).to eq(1)
  end
end
