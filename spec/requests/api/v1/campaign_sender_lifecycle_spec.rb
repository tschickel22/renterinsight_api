# frozen_string_literal: true

require 'rails_helper'

# Reopen, resume and sender choice for campaigns whose sender stopped working.
RSpec.describe 'Api::V1::Campaigns sender lifecycle', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  let(:home)    { Company.create!(name: "Home-#{SecureRandom.hex(4)}") }
  let(:admin) do
    User.create!(email: "a-#{SecureRandom.hex(4)}@example.com", first_name: 'A', last_name: 'D',
                 password: 'Pass1234!', company_id: home.id, role: 'platform_admin')
  end
  let(:rep) do
    User.create!(email: "r-#{SecureRandom.hex(4)}@example.com", first_name: 'R', last_name: 'P',
                 password: 'Pass1234!', company_id: company.id, role: 'admin')
  end

  def headers_for(user)
    token = JsonWebToken.encode(user_id: user.id, company_id: company.id)
    { 'Authorization' => "Bearer #{token}", 'Content-Type' => 'application/json', 'X-Company-ID' => company.id.to_s }
  end

  def campaign(**attrs)
    Campaign.create!({ company_id: company.id, created_by_user_id: rep.id, name: 'Series', campaign_type: 'drip',
                       channel: 'email', from_identity_type: 'User', from_identity_id: rep.id,
                       throttle_per_day: 100 }.merge(attrs))
  end

  def connect(user, company_id: company.id)
    UserEmailConnection.create!(user_id: user.id, company_id: company_id, provider: 'oauth_outlook',
                                email_address: user.email, is_active: true,
                                oauth_token_encrypted: 'x', oauth_refresh_token_encrypted: 'y')
  end

  describe 'POST /reopen' do
    it 'moves a completed campaign back to paused so it can be edited and resumed' do
      c = campaign(status: 'completed', completed_at: 1.day.ago)

      post "/api/v1/campaigns/#{c.id}/reopen", headers: headers_for(admin)

      expect(response).to have_http_status(:ok)
      expect(c.reload).to have_attributes(status: 'paused', completed_at: nil)
    end

    it 'refuses a campaign that is not completed' do
      c = campaign(status: 'running')

      post "/api/v1/campaigns/#{c.id}/reopen", headers: headers_for(admin)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(c.reload.status).to eq('running')
    end
  end

  describe 'POST /resume' do
    it 'refuses while the sender still cannot send, and says what to fix' do
      mailbox = connect(rep)
      mailbox.update_columns(last_error_message: 'Reauth required: invalid_grant')
      c = campaign(status: 'paused', pause_reason: { 'code' => 'sender_needs_reauth' })

      post "/api/v1/campaigns/#{c.id}/resume", headers: headers_for(admin)

      expect(response).to have_http_status(:unprocessable_entity)
      body = JSON.parse(response.body)
      expect(body).to include('code' => 'sender_needs_reauth', 'reconnect_path' => '/account/settings?tab=email')
      expect(body['error']).to include('reconnected')
      expect(c.reload.status).to eq('paused')
    end

    it 'resumes once the sender works and clears the reason' do
      connect(rep)
      c = campaign(status: 'paused', paused_at: 1.hour.ago, pause_reason: { 'code' => 'sender_needs_reauth' })

      post "/api/v1/campaigns/#{c.id}/resume", headers: headers_for(admin)

      expect(response).to have_http_status(:ok)
      expect(c.reload).to have_attributes(status: 'running', pause_reason: nil, paused_at: nil)
      expect(JSON.parse(response.body)).to include('pause_reason' => nil)
    end
  end

  describe 'choosing a sender' do
    it 'lets a platform admin send as themselves in a company they do not belong to' do
      connect(admin, company_id: home.id)
      c = campaign(status: 'paused')

      patch "/api/v1/campaigns/#{c.id}", params: { campaign: { from_identity_id: admin.id } }.to_json,
                                         headers: headers_for(admin)

      expect(response).to have_http_status(:ok)
      expect(c.reload.from_identity_id).to eq(admin.id)
    end

    it 'does not let anyone pick a user from another company' do
      outsider = User.create!(email: "o-#{SecureRandom.hex(4)}@example.com", first_name: 'O', last_name: 'U',
                              password: 'Pass1234!', company_id: home.id)
      c = campaign(status: 'paused')

      patch "/api/v1/campaigns/#{c.id}", params: { campaign: { from_identity_id: outsider.id } }.to_json,
                                         headers: headers_for(admin)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(c.reload.from_identity_id).to eq(rep.id)
    end

    it "does not let a tenant user pick a platform admin" do
      # Permission to edit campaigns is granted; the sender rule is what is under test.
      allow_any_instance_of(Api::V1::CampaignsController).to receive(:authorize_action!).and_return(true)
      c = campaign(status: 'paused')

      patch "/api/v1/campaigns/#{c.id}", params: { campaign: { from_identity_id: admin.id } }.to_json,
                                         headers: headers_for(rep)

      expect(response).to have_http_status(:unprocessable_entity)
    end

    it 'lists a platform admin their own mailbox from their home company' do
      own = connect(admin, company_id: home.id)

      get '/api/v1/email_senders', headers: headers_for(admin)

      ids = JSON.parse(response.body)['user_senders'].map { |s| s['connection_id'] }
      expect(ids).to include(own.id)
    end
  end
end
