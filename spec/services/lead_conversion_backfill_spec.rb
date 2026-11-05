# frozen_string_literal: true

require 'rails_helper'

RSpec.describe LeadConversionBackfill do
  let(:company) { create(:company) }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'U', last_name: 'Ser', password: 'Password123!',
                 company_id: company.id, role: 'company_admin', status: 'active')
  end
  let(:account) { company.accounts.create!(name: 'Holloway Family') }
  let(:lead) do
    Lead.create!(company: company, first_name: 'Megan', last_name: 'Holloway', email: 'megan@example.com', phone: '3035550142',
                 status: 'qualified', is_converted: true, converted_account_id: account.id)
  end
  let!(:copied_open) do
    la = lead.lead_activities.create!(activity_type: 'reminder', subject: 'Call back', description: 'Call back', status: 'pending',
                                      user_id: user.id, reminder_time: 2.days.from_now, reminder_method: ['popup'])
    LeadConversionCarry.copy_activity(la, account: account, lead: lead)
    la.update_columns(status: 'pending', reminder_sent: false) # what earlier conversions left behind
    la
  end
  let!(:dropped_call) do
    la = lead.lead_activities.create!(activity_type: 'call', subject: 'No number call', status: 'completed', user_id: user.id, call_direction: 'inbound')
    la
  end
  let!(:tag) do
    t = Tag.create!(company_id: company.id, name: 'hot')
    TagAssignment.create!(tag: t, entity_type: 'Lead', entity_id: lead.id, company_id: company.id, assigned_at: Time.current)
    t
  end
  let!(:note) { Note.create!(entity_type: 'Lead', entity_id: lead.id.to_s, content: 'Wants three bedrooms', created_by_name: 'Sam') }

  it 'counts without writing on a dry run' do
    result = described_class.call

    expect(result).to include(leads: 1, activities_copied: 1, open_activities_retired: 1, tags_copied: 1, notes_copied: 1, applied: false)
    expect(account.activities.count).to eq(1)
    expect(copied_open.reload.status).to eq('pending')
  end

  it 'copies what is missing, retires the open duplicate, and does nothing more the second time' do
    described_class.call(apply: true)

    expect(account.activities.pluck(:subject)).to contain_exactly('Call back', 'No number call')
    expect(copied_open.reload).to have_attributes(status: 'cancelled', reminder_sent: true)
    expect(account.tags).to contain_exactly(tag)
    expect(Note.for_entity('account', account.id.to_s).pluck(:content)).to eq(['Wants three bedrooms'])

    again = described_class.call(apply: true)

    expect(again).to include(activities_copied: 0, tags_copied: 0, notes_copied: 0, open_activities_retired: 0)
    expect(account.activities.count).to eq(2)
  end
end
