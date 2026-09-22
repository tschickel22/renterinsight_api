# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Campaign consent coverage', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(3)}") }
  let(:admin) do
    User.create!(email: "a-#{SecureRandom.hex(4)}@example.com", first_name: 'A', last_name: 'D',
                 password: 'Pass1234!', company_id: company.id, role: 'company_admin')
  end
  let(:headers) do
    { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: admin.id, company_id: company.id)}" }
  end
  let(:campaign) do
    c = Campaign.create!(company_id: company.id, created_by_user_id: admin.id, name: 'Weekly',
                         campaign_type: 'blast', channel: 'email', from_identity_type: 'User',
                         from_identity_id: admin.id, throttle_per_day: 100)
    c.campaign_steps.create!(position: 0, channel: 'email', subject: 'Hi',
                             body_blocks: [{ 'type' => 'text', 'html' => 'Hi' }])
    c
  end

  def enrolled_lead(consent: nil)
    lead = Lead.create!(company_id: company.id, first_name: 'S', last_name: 'K',
                        email: "l-#{SecureRandom.hex(4)}@example.com")
    unless consent.nil?
      pref = CommunicationPreference.find_or_create_for(recipient: lead, channel: 'email', category: 'marketing')
      consent ? pref.opt_in! : pref.opt_out!('no')
    end
    CampaignEnrollment.create!(company_id: company.id, campaign_id: campaign.id, recipient_type: 'Lead',
                               recipient_id: lead.id, email_address_snapshot: lead.email, status: 'pending')
    lead
  end

  it 'reports how many recipients will be skipped' do
    enrolled_lead(consent: true)
    enrolled_lead
    enrolled_lead(consent: false)

    get "/api/v1/campaigns/#{campaign.id}/consent_coverage", headers: headers

    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    expect(body['total']).to eq(3)
    expect(body['consented']).to eq(1)
    expect(body['missing']).to eq(1)
    expect(body['optedOut']).to eq(1)
    expect(body['willBeSkipped']).to eq(2)
  end

  it 'reports nothing skipped for a tenant that opted out of the gate' do
    Setting.set('Company', company.id, 'require_marketing_consent', false)
    enrolled_lead

    get "/api/v1/campaigns/#{campaign.id}/consent_coverage", headers: headers

    body = JSON.parse(response.body)
    expect(body['gateEnabled']).to be(false)
    expect(body['willBeSkipped']).to eq(0)
  end

  it 'confirms the never-asked recipients and returns fresh counts' do
    never_asked = enrolled_lead
    refuser = enrolled_lead(consent: false)

    post "/api/v1/campaigns/#{campaign.id}/confirm_audience_consent",
         params: { basis: 'Imported from previous CRM' }, headers: headers

    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    expect(body['confirmed']).to eq(1)
    expect(body['coverage']['missing']).to eq(0)
    expect(CommunicationPreference.marketing_consent?(recipient: never_asked)).to be(true)
    # The one who answered keeps their answer.
    expect(CommunicationPreference.marketing_consent?(recipient: refuser)).to be(false)
  end

  it 'will not confirm without a stated basis' do
    enrolled_lead

    post "/api/v1/campaigns/#{campaign.id}/confirm_audience_consent",
         params: {}, headers: headers

    expect(response).to have_http_status(:unprocessable_entity)
    expect(CommunicationPreference.count).to eq(0)
  end
end

# The other half of "will this campaign actually send anything": whether there
# is anyone to send as. Owner mode resolves per recipient, so a campaign can
# start and then send nothing because its reps are on Gmail or have no mailbox.
RSpec.describe 'Campaign sender coverage', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(3)}") }
  let(:admin) do
    User.create!(email: "a-#{SecureRandom.hex(4)}@example.com", first_name: 'A', last_name: 'D',
                 password: 'Pass1234!', company_id: company.id, role: 'company_admin')
  end
  let(:headers) do
    { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: admin.id, company_id: company.id)}" }
  end
  let(:campaign) do
    c = Campaign.create!(company_id: company.id, created_by_user_id: admin.id, name: 'W',
                         campaign_type: 'blast', channel: 'email', from_identity_type: 'Owner',
                         throttle_per_day: 100)
    c.campaign_steps.create!(position: 0, channel: 'email', subject: 'Hi',
                             body_blocks: [{ 'type' => 'text', 'html' => 'Hi' }])
    c
  end

  def rep_with(provider, email)
    u = User.create!(email: email, first_name: 'R', last_name: 'P',
                     password: 'Pass1234!', company_id: company.id)
    UserEmailConnection.create!(company_id: company.id, user_id: u.id, provider: provider,
                                email_address: email, is_active: true)
    u
  end

  def enrol(owner)
    lead = Lead.create!(company_id: company.id, first_name: 'S', last_name: 'K',
                        owner_id: owner&.id, email: "l-#{SecureRandom.hex(4)}@example.com")
    CampaignEnrollment.create!(company_id: company.id, campaign_id: campaign.id, recipient_type: 'Lead',
                               recipient_id: lead.id, email_address_snapshot: lead.email, status: 'pending')
  end

  it 'names the owners who cannot send and why' do
    enrol(rep_with('oauth_outlook', 'ok@dealer.example'))
    enrol(rep_with('oauth_gmail', 'sells@gmail.com'))
    enrol(nil)

    get "/api/v1/campaigns/#{campaign.id}/sender_coverage", headers: headers

    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    expect(body['total']).to eq(3)
    expect(body['usable']).to eq(1)
    expect(body['google']).to eq(1)
    expect(body['missing']).to eq(1)

    gmail = body['owners'].find { |o| o['reason'] == 'google' }
    expect(gmail['name']).to eq('sells@gmail.com')
    expect(gmail['count']).to eq(1)
  end

  it 'reports a clear audience with nothing to warn about' do
    enrol(rep_with('oauth_outlook', 'ok@dealer.example'))

    get "/api/v1/campaigns/#{campaign.id}/sender_coverage", headers: headers

    body = JSON.parse(response.body)
    expect(body['blocked']).to eq(0)
    expect(body['owners']).to be_empty
  end
end
