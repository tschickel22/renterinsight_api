# frozen_string_literal: true

require 'rails_helper'

# The Inbox (E96): conversations by who has them, and the controls that move
# them between the Lead Assistant and a person.
RSpec.describe 'Inbox conversations', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  let(:admin) do
    User.create!(email: "a-#{SecureRandom.hex(4)}@example.com", first_name: 'Ada', last_name: 'Admin', password: 'Pass1234!',
                 company_id: company.id, role: 'company_admin', status: 'active')
  end
  let(:rep) do
    User.create!(email: "r-#{SecureRandom.hex(4)}@example.com", first_name: 'Jordan', last_name: 'Rep', password: 'Pass1234!',
                 company_id: company.id, role: 'sales_rep', status: 'active')
  end
  let(:headers) do
    { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: admin.id, company_id: company.id)}", 'Content-Type' => 'application/json' }
  end

  def lead(name, phone)
    company.leads.create!(first_name: name, last_name: 'Buyer', phone: phone, owner_id: rep.id)
  end

  def conversation(record, **attrs)
    Conversation.create!({ company: company, conversable: record, sender_number: '+17205550100', buyer_phone: record.phone,
                           status: 'active', started_at: 1.hour.ago, assigned_user_id: rep.id }.merge(attrs))
  end

  let!(:assistant_has_it) { conversation(lead('Tia', '3035550101'), last_inbound_at: 5.minutes.ago, last_message_at: 4.minutes.ago) }
  let!(:handed_off) do
    conversation(lead('Ray', '3035550102'), status: 'handed_off', handoff_reason: 'finance_or_credit',
                                            handed_off_to_user_id: admin.id, last_inbound_at: 3.minutes.ago, last_message_at: 2.minutes.ago,
                                            last_message_preview: 'What would my payment be?')
  end
  let!(:answered) do
    conversation(lead('Sue', '3035550103'), status: 'handed_off', last_inbound_at: 30.minutes.ago,
                                            last_person_reply_at: 20.minutes.ago, last_message_at: 20.minutes.ago, assigned_user_id: nil)
  end
  let!(:finished) { conversation(lead('Al', '3035550104'), status: 'closed', last_message_at: 1.day.ago) }

  def list(**params)
    get '/api/crm/conversations', headers: headers, params: { location_id: 'all' }.merge(params)
    expect(response).to have_http_status(:ok)
    JSON.parse(response.body)
  end

  it 'lists open conversations newest first, with who has each one' do
    body = list
    expect(body['items'].map { |r| r['id'] }).to eq([handed_off.id, assistant_has_it.id, answered.id])
    states = body['items'].to_h { |r| [r['id'], r['state']] }
    expect(states).to eq(handed_off.id => 'Needs you', assistant_has_it.id => 'Assistant', answered.id => 'Waiting on buyer')
    expect(body['meta']['counts']).to include('needs_you' => 1, 'unassigned' => 1)
    expect(body['items'].first['handoff_label']).to eq('asked about payments or credit')
  end

  it 'has the views from the mockup' do
    expect(list(view: 'needs_you')['items'].map { |r| r['id'] }).to eq([handed_off.id])
    expect(list(view: 'mine')['items'].map { |r| r['id'] }).to eq([handed_off.id])
    expect(list(view: 'unassigned')['items'].map { |r| r['id'] }).to eq([answered.id])
    expect(list(view: 'done')['items'].map { |r| r['id'] }).to eq([finished.id])
    expect(list(handled_by: 'assistant')['items'].map { |r| r['id'] }).to eq([assistant_has_it.id])
    expect(list(q: 'Ray')['items'].map { |r| r['id'] }).to eq([handed_off.id])
    expect(list(q: '0103')['items'].map { |r| r['id'] }).to eq([answered.id])
  end

  it 'marks unread until opened' do
    expect(list['items'].find { |r| r['id'] == handed_off.id }['unread']).to be(true)
    post "/api/crm/conversations/#{handed_off.id}/read", headers: headers
    expect(list['items'].find { |r| r['id'] == handed_off.id }['unread']).to be(false)
  end

  it 'takes over from the assistant, hands back, and closes' do
    post "/api/crm/conversations/#{assistant_has_it.id}/take_over", headers: headers
    expect(assistant_has_it.reload).to have_attributes(status: 'handed_off', handed_off_to_user_id: admin.id)

    post "/api/crm/conversations/#{assistant_has_it.id}/hand_back", headers: headers
    expect(response).to have_http_status(:unprocessable_entity) # add-on not on

    TenantModuleOverride.create!(company: company, module_key: 'marketing.lead_assistant', is_enabled: true)
    Assistant::Settings.for(company).update!('enabled' => true)
    post "/api/crm/conversations/#{assistant_has_it.id}/hand_back", headers: headers
    expect(assistant_has_it.reload.status).to eq('active')

    post "/api/crm/conversations/#{assistant_has_it.id}/done", headers: headers
    expect(assistant_has_it.reload.status).to eq('closed')
  end

  it 'assigns and finds the conversation for a record' do
    post "/api/crm/conversations/#{answered.id}/assign", headers: headers, params: { user_id: admin.id }.to_json
    expect(answered.reload.assigned_user_id).to eq(admin.id)

    get '/api/crm/conversations/for_record', headers: headers, params: { type: 'Lead', id: handed_off.conversable_id, location_id: 'all' }
    expect(JSON.parse(response.body)['conversation']['id']).to eq(handed_off.id)
  end

  it 'never shows another company the conversation' do
    other = Company.create!(name: "Other-#{SecureRandom.hex(3)}")
    stranger = User.create!(email: "s-#{SecureRandom.hex(4)}@example.com", first_name: 'S', last_name: 'X', password: 'Pass1234!',
                            company_id: other.id, role: 'company_admin', status: 'active')
    h = { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: stranger.id, company_id: other.id)}" }
    get "/api/crm/conversations/#{handed_off.id}", headers: h
    expect(response).to have_http_status(:not_found)
  end

  it 'sends a reply typed in the thread on the conversation, and takes it from the assistant' do
    sent = []
    allow_any_instance_of(Providers::Sms::TwilioProvider).to receive(:send_message) do |_p, **args|
      sent << args
      { success: true, external_id: "SM#{SecureRandom.hex(6)}", provider: 'twilio' }
    end
    record = assistant_has_it.conversable
    post '/api/platform/communications/sms', headers: headers,
         params: { entity_type: 'Lead', entity_id: record.id, to: record.phone, message: 'Hi Tia, Ada here - free Saturday?' }.to_json
    expect(response.status).to be < 300
    comm = Communication.find(JSON.parse(response.body)['id'])
    expect(comm).to have_attributes(conversation_id: assistant_has_it.id, from_address: '+17205550100')
    expect(sent.last[:body]).to eq('Hi Tia, Ada here - free Saturday?')
    expect(assistant_has_it.reload).to have_attributes(status: 'handed_off', handed_off_to_user_id: admin.id)
    expect(assistant_has_it.last_person_reply_at).to be_present
  end

  it 'saves the Lead Assistant settings only with the add-on' do
    patch '/api/crm/lead_assistant_settings', headers: headers, params: { settings: { enabled: true } }.to_json
    expect(response).to have_http_status(:forbidden)

    TenantModuleOverride.create!(company: company, module_key: 'marketing.lead_assistant', is_enabled: true)
    patch '/api/crm/lead_assistant_settings', headers: headers,
                                              params: { settings: { enabled: true, assistant_name: 'Judy', tone: 'professional', source_ids: 'all' } }.to_json
    body = JSON.parse(response.body)
    expect(body['settings']).to include('enabled' => true, 'assistant_name' => 'Judy', 'tone' => 'professional')
    expect(body['texting']['sends_from']).to eq('none')
  end
end
