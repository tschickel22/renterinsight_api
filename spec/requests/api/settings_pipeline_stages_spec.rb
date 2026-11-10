# frozen_string_literal: true

require 'rails_helper'

# The Pipeline Stages settings tab reads and saves through these endpoints.
# What it shows for an unsaved pipeline must be what the deals board uses
# (Company::DEFAULT_PIPELINE_STAGES), and the locked Closed Won / Closed Lost
# stages must hold on the server, not only in the browser.
RSpec.describe 'Settings pipeline stages', type: :request do
  let(:company) { create(:company, use_rbac_system: false) }
  let(:user) do
    User.create!(email: "admin-#{SecureRandom.hex(3)}@example.com", password: 'Password123!', company: company,
                 first_name: 'Admin', last_name: 'User')
  end
  let(:headers) { { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}" } }

  def default_payload
    get '/api/settings/pipeline_stages', headers: headers
    JSON.parse(response.body)['stages']
  end

  def patch_stages(stages)
    patch '/api/settings/pipeline_stages', params: { stages: stages }, headers: headers, as: :json
  end

  describe 'GET for a company that never saved its pipeline' do
    it 'returns the same stages the deals board uses' do
      stages = default_payload
      expect(response).to have_http_status(:ok)
      expect(stages.map { |s| s['key'] }).to eq(Company::DEFAULT_PIPELINE_STAGES.map { |s| s['key'] })
      expect(stages.map { |s| s['name'] }).to eq(Company::DEFAULT_PIPELINE_STAGES.map { |s| s['name'] })
      expect(stages.map { |s| s['key'] }).to eq(company.pipeline_stage_keys)
    end

    it 'carries the default probabilities, colors and the active flag' do
      stages = default_payload
      stages.each do |s|
        expect(s['probability']).to eq(Company::DEFAULT_STAGE_PROBABILITIES[s['key']])
        expect(s['color']).to be_present
        expect(s['active']).to eq(true)
      end
    end

    it 'treats an empty saved list as unsaved, like the board does' do
      Setting.set('Company', company.id, 'pipeline_stages', [])
      expect(default_payload.map { |s| s['key'] }).to eq(company.pipeline_stage_keys)
    end

    it 'returns a saved pipeline unchanged' do
      saved = [{ 'key' => 'lead', 'name' => 'Lead', 'probability' => 10, 'order' => 0 }]
      Setting.set('Company', company.id, 'pipeline_stages', saved)
      expect(default_payload.map { |s| s['key'] }).to eq(['lead'])
    end
  end

  describe 'PATCH and the locked stages' do
    it 'saves the default list as loaded' do
      patch_stages(default_payload)
      expect(response).to have_http_status(:ok)
    end

    it 'still allows reordering and changing probability and color of a locked stage' do
      stages = default_payload
      won = stages.find { |s| s['key'] == 'closed_won' }
      won['color'] = '#3b82f6'
      stages = [won] + stages.reject { |s| s['key'] == 'closed_won' }
      patch_stages(stages)
      expect(response).to have_http_status(:ok)
    end

    it 'rejects dropping Closed Won' do
      patch_stages(default_payload.reject { |s| s['key'] == 'closed_won' }.tap { |l| l.first['probability'] = 100 })
      expect(response).to have_http_status(:unprocessable_entity)
      expect(Setting.get('Company', company.id, 'pipeline_stages', nil)).to be_nil
    end

    it 'rejects changing the key of Closed Lost' do
      stages = default_payload
      stages.find { |s| s['key'] == 'closed_lost' }['key'] = 'dead'
      patch_stages(stages)
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it 'rejects renaming a locked stage' do
      stages = default_payload
      stages.find { |s| s['key'] == 'closed_won' }['name'] = 'Sold'
      patch_stages(stages)
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it 'rejects switching a locked stage off' do
      stages = default_payload
      stages.find { |s| s['key'] == 'closed_lost' }['active'] = false
      patch_stages(stages)
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it 'does not force locked stages onto a saved pipeline that never had them' do
      Setting.set('Company', company.id, 'pipeline_stages', [
        { 'key' => 'lead', 'name' => 'Lead', 'probability' => 10, 'order' => 0 },
        { 'key' => 'won', 'name' => 'Won', 'probability' => 100, 'order' => 1 },
        { 'key' => 'lost', 'name' => 'Lost', 'probability' => 0, 'order' => 2 }
      ])
      patch_stages(default_payload.reject { |s| s['key'] == 'lead' })
      expect(response).to have_http_status(:ok)
    end
  end

  describe 'who can save' do
    let(:company) { create(:company, use_rbac_system: true) }
    let(:user) do
      User.create!(email: "rep-#{SecureRandom.hex(3)}@example.com", password: 'Password123!', company: company,
                   first_name: 'Sales', last_name: 'Rep', role: 'user', status: 'active')
    end

    it 'refuses someone without permission to change company settings' do
      patch_stages(Company::DEFAULT_PIPELINE_STAGES.map { |st| st.merge('active' => true) })
      expect(response).to have_http_status(:forbidden)
      expect(Setting.get('Company', company.id, 'pipeline_stages', nil)).to be_nil
    end
  end
end
