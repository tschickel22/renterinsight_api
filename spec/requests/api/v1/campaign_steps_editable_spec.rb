# frozen_string_literal: true

require 'rails_helper'

# Regression: the step/audience/update lock error says "Pause it to edit", but
# `editable?` only allowed draft/scheduled — so pausing never unlocked editing
# and users hit "Campaign is locked. Pause it to edit." on a paused campaign.
RSpec.describe 'Campaign step editability by status', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(3)}") }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(3)}@example.com", first_name: 'T', last_name: 'U',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
  end
  let(:token) { JsonWebToken.encode(user_id: user.id, company_id: company.id) }
  let(:headers) { { 'Authorization' => "Bearer #{token}", 'Content-Type' => 'application/json' } }

  let(:campaign) do
    c = Campaign.create!(company_id: company.id, created_by_user_id: user.id, name: 'C',
                         campaign_type: 'blast', from_identity_type: 'User', from_identity_id: user.id,
                         throttle_per_day: 100)
    c.campaign_steps.create!(position: 0, channel: 'email', subject: 'Original',
                             body_blocks: [{ 'type' => 'text', 'html' => 'x' }])
    c
  end
  let(:step) { campaign.campaign_steps.first }

  def patch_subject
    patch "/api/v1/campaigns/#{campaign.id}/steps/#{step.id}",
          params: { campaign_step: { subject: 'Edited' } }.to_json, headers: headers
  end

  it 'allows editing a step when the campaign is paused' do
    campaign.update!(status: 'paused')
    patch_subject
    expect(response).to have_http_status(:ok)
    expect(step.reload.subject).to eq('Edited')
  end

  it 'allows editing a step when the campaign is draft' do
    campaign.update!(status: 'draft')
    patch_subject
    expect(response).to have_http_status(:ok)
  end

  it 'locks editing a step while the campaign is running' do
    campaign.update!(status: 'running')
    patch_subject
    expect(response).to have_http_status(:unprocessable_entity)
    expect(JSON.parse(response.body)['error']).to match(/Pause it to edit/i)
    expect(step.reload.subject).to eq('Original')
  end
end
