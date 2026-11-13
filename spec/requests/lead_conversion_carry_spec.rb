# frozen_string_literal: true

require 'rails_helper'

# The convert dialog promised notes, tags and reminders moved to the account, and
# only activities did.
RSpec.describe 'What a converted lead brings to its account', type: :request do
  let(:company) { create(:company) }
  let(:admin) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'U', last_name: 'Ser', password: 'Password123!',
                 company_id: company.id, role: 'company_admin', status: 'active')
  end
  let(:lead) do
    Lead.create!(company: company, first_name: 'Megan', last_name: 'Holloway', email: 'megan@example.com', phone: '3035550142',
                 status: 'qualified', notes: 'Family land near Greeley', owner_id: admin.id)
  end
  let(:account) { company.accounts.find_by!(name: 'Megan Holloway') }

  def convert(name = 'Megan Holloway', mode: nil)
    post "/api/crm/leads/#{lead.id}/convert", params: { account_name: name, account_mode: mode }.compact,
                                              headers: { 'Authorization' => "Bearer #{JsonWebToken.generate_access_token(admin)}", 'X-Company-ID' => company.id.to_s }
    expect(response).to have_http_status(:ok), response.body
  end

  it 'brings its tags and fires no workflow for them' do
    tag = Tag.create!(company_id: company.id, name: 'hot', tag_type: 'lead') rescue Tag.create!(company_id: company.id, name: 'hot')
    TagAssignment.create!(tag: tag, entity_type: 'Lead', entity_id: lead.id, company_id: company.id, assigned_at: Time.current)
    allow(WorkflowEngine).to receive(:emit)

    convert

    expect(account.tags).to contain_exactly(tag)
    expect(WorkflowEngine).not_to have_received(:emit).with('account.tagged', any_args)
  end

  it 'brings both spellings of its notes, with author and date' do
    Note.create!(entity_type: 'Lead', entity_id: lead.id.to_s, content: 'Called twice', created_by_name: 'Alex Morgan', created_at: 3.days.ago)
    Note.create!(entity_type: 'lead', entity_id: lead.id.to_s, content: 'Wants three bedrooms', created_by_name: 'Sam Reyes')

    convert

    notes = Note.for_entity('account', account.id.to_s)
    expect(notes.pluck(:content)).to contain_exactly('Called twice', 'Wants three bedrooms')
    expect(notes.find_by(content: 'Called twice')).to have_attributes(created_by_name: 'Alex Morgan')
    expect(notes.find_by(content: 'Called twice').created_at).to be < 2.days.ago
  end

  it 'keeps the lead notes field when it joins an account that already exists' do
    existing = company.accounts.create!(name: 'Holloway Family', notes: 'Bought in 2019')

    convert('Holloway Family', mode: 'existing')

    expect(existing.reload.notes).to eq('Bought in 2019')
    expect(Note.for_entity('account', existing.id.to_s).pluck(:content)).to include('Family land near Greeley')
  end

  it 'moves an open activity so the rep is reminded once, and leaves finished ones as they were' do
    open = lead.lead_activities.create!(activity_type: 'reminder', subject: 'Call back', description: 'Call back', status: 'pending', user_id: admin.id,
                                        reminder_time: 2.days.from_now, reminder_method: ['popup'])
    done = lead.lead_activities.create!(activity_type: 'call', subject: 'First call', status: 'completed', user_id: admin.id, call_direction: 'outbound')

    convert

    expect(account.activities.pluck(:subject)).to contain_exactly('Call back', 'First call')
    expect(account.activities.find_by(subject: 'Call back')).to have_attributes(status: 'pending', reminder_sent: false)
    expect(open.reload).to have_attributes(status: 'cancelled', reminder_sent: true)
    expect(done.reload.status).to eq('completed')
  end

  it 'never drops a call because the lead has no phone number' do
    lead.update_columns(phone: nil)
    lead.lead_activities.create!(activity_type: 'call', subject: 'Walk-in call', status: 'completed', user_id: admin.id, call_direction: 'inbound')

    convert

    expect(account.activities.pluck(:subject)).to contain_exactly('Walk-in call')
  end

  it 'moves open reminders and tasks from the older tables and skips finished ones' do
    lead.reminders.create!(user_id: admin.id, reminder_type: 'call', title: 'Ring Megan', due_date: 1.day.from_now)
    lead.reminders.create!(user_id: admin.id, reminder_type: 'call', title: 'Old', due_date: 1.day.ago, is_completed: true)
    lead.lead_tasks.create!(title: 'Send floor plans', due_at: 2.days.from_now, done: false)
    lead.lead_tasks.create!(title: 'Done task', done: true)

    convert

    expect(account.activities.pluck(:subject)).to contain_exactly('Ring Megan', 'Send floor plans')
    expect(account.activities.find_by(subject: 'Send floor plans')).to have_attributes(activity_type: 'task', status: 'pending', assigned_to_id: admin.id)
    expect(lead.reminders.where(is_completed: [false, nil])).to be_empty
    expect(lead.lead_tasks.where(done: [false, nil])).to be_empty
  end

  it 'leaves scores and AI insights on the lead' do
    convert

    expect(account).not_to respond_to(:lead_scores)
  end
end
