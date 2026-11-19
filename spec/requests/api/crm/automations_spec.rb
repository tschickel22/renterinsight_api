# frozen_string_literal: true

require 'rails_helper'

# Everything messaging one lead or contact, and Stop (E105 follow-up).
RSpec.describe 'Automations on a record', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(3)}") }
  let(:rep) do
    User.create!(email: "rep-#{SecureRandom.hex(3)}@example.com", first_name: 'Rita', last_name: 'Rep',
                 password: 'Pass1234!', company_id: company.id, role: 'company_admin', status: 'active')
  end
  let(:headers) { { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: rep.id, company_id: company.id)}" } }
  let(:lead) do
    company.leads.create!(first_name: 'Pat', last_name: 'Lee', email: 'pat@example.com', phone: '3035551234', owner_id: rep.id,
                          status: 'new', sms_inquiry_consent: true)
  end
  let(:sequence) { NurtureSequence.create!(name: 'New lead follow-up', company_id: company.id) }
  let(:campaign) do
    Campaign.create!(company_id: company.id, created_by_user_id: rep.id, name: 'Fall promo', campaign_type: 'blast',
                     from_identity_type: 'User', from_identity_id: rep.id, throttle_per_day: 10)
  end
  let(:rule) do
    WorkflowRule.create!(company_id: company.id, name: 'Hot lead path', entity_type: 'Lead', status: 'active',
                         trigger: { 'event_type' => 'lead.tagged' }, conditions: { 'type' => 'and', 'children' => [] },
                         steps: { 'nodes' => [{ 'id' => 'n1', 'type' => 'wait', 'config' => { 'duration' => 1 } }] })
  end

  def enroll_everything
    @nurture = NurtureEnrollment.create!(enrollable: lead, company_id: company.id, nurture_sequence_id: sequence.id, status: 'running')
    @campaign_enrollment = CampaignEnrollment.create!(company_id: company.id, campaign_id: campaign.id, recipient_type: 'Lead',
                                                      recipient_id: lead.id, status: 'active', sms_phone_snapshot: lead.phone)
    @run = WorkflowRun.create!(company: company, workflow_rule: rule, entity_type: 'Lead', entity_id: lead.id, status: 'waiting',
                               current_step_id: 'n1', started_at: Time.current, rule_snapshot: rule.steps, wait_until: 1.day.from_now)
    @conversation = company.conversations.create!(conversable: lead, sender_number: '+17205550100', buyer_phone: lead.phone,
                                                  assigned_user_id: rep.id, started_at: Time.current)
  end

  def list
    get '/api/crm/automations', params: { record_type: 'Lead', record_id: lead.id }, headers: headers
    JSON.parse(response.body)
  end

  def notes
    Note.where(entity_type: 'lead', entity_id: lead.id.to_s).pluck(:content)
  end

  it 'lists every kind with a plain name' do
    enroll_everything
    body = list

    expect(response).to have_http_status(:ok)
    expect(body['items'].map { |i| [i['kind'], i['name']] }).to contain_exactly(
      %w[nurture New\ lead\ follow-up], ['campaign', 'Fall promo'], ['workflow', 'Hot lead path'], ['conversation', 'Quinn text conversation']
    )
    expect(body['active_count']).to eq(4)
  end

  it 'stops one without unsubscribing, notes it, and frees the lead for outreach' do
    enroll_everything
    post '/api/crm/automations/stop', params: { record_type: 'Lead', record_id: lead.id, kind: 'campaign', id: @campaign_enrollment.id }, headers: headers

    expect(response).to have_http_status(:ok)
    expect(@campaign_enrollment.reload.status).to eq('paused')
    expect(CampaignSuppression.where(company_id: company.id).count).to eq(0)
    expect(JSON.parse(response.body)['items'].map { |i| i['kind'] }).not_to include('campaign')
    expect(notes.last).to include('Stopped campaign "Fall promo"', 'Rita Rep', 'Nothing was unsubscribed')
  end

  it 'stops everything at once, and outreach then sees nothing in the way' do
    enroll_everything
    post '/api/crm/automations/stop_all', params: { record_type: 'Lead', record_id: lead.id }, headers: headers

    body = JSON.parse(response.body)
    expect(body['stopped']).to eq(4)
    expect(body['items']).to be_empty
    expect(@nurture.reload.status).to eq('completed')
    expect(@run.reload.status).to eq('cancelled')
    expect(@conversation.reload.status).to eq('closed')
    expect(Outreach::Eligibility.new(company).on_automation?(lead)).to be(false)
    expect(LeadActivity.where(lead_id: lead.id)).to be_empty
  end

  it 'shows a starter play as one row and stops all its parts for this lead only' do
    enroll_everything
    play = Plays::Registry.all.find { |p| p::KEY != 'deal_to_sold' }
    PlayInstallation.create!(company: company, play_key: play::KEY, status: 'active',
                             assets: { 'workflow_rule_ids' => [rule.id], 'nurture_sequence_ids' => [sequence.id] })
    body = list
    kinds = body['items'].map { |i| i['kind'] }
    expect(kinds).to contain_exactly('play', 'campaign', 'conversation')
    row = body['items'].find { |i| i['kind'] == 'play' }
    expect(row['name']).to eq(play::NAME)

    post '/api/crm/automations/stop', params: { record_type: 'Lead', record_id: lead.id, kind: 'play', id: row['id'] }, headers: headers
    expect(@run.reload.status).to eq('cancelled')
    expect(@nurture.reload.status).to eq('completed')
    expect(rule.reload.status).to eq('active')
  end

  it 'refuses something that is no longer running' do
    post '/api/crm/automations/stop', params: { record_type: 'Lead', record_id: lead.id, kind: 'nurture', id: 999_999 }, headers: headers
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it 'works for a contact and never reaches another company' do
    contact = Contact.create!(company_id: company.id, first_name: 'Sam', last_name: 'K', email: 'sam@example.com')
    NurtureEnrollment.create!(enrollable: contact, company_id: company.id, nurture_sequence_id: sequence.id, status: 'running')
    get '/api/crm/automations', params: { record_type: 'Contact', record_id: contact.id }, headers: headers
    expect(JSON.parse(response.body)['items'].map { |i| i['kind'] }).to eq(['nurture'])

    other = Company.create!(name: "Other-#{SecureRandom.hex(3)}")
    stranger = Contact.create!(company_id: other.id, first_name: 'X', last_name: 'Y', email: 'x@example.com')
    get '/api/crm/automations', params: { record_type: 'Contact', record_id: stranger.id }, headers: headers
    expect(response).to have_http_status(:not_found)
  end
end
