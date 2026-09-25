# frozen_string_literal: true

require 'rails_helper'

# The compose screen saves hashtags, ad settings and "submit for approval",
# none of which have a column. Each one was either dropped on save or not
# returned on load, so it silently vanished between the two.
RSpec.describe 'Api::V1::SocialPosts compose round trip', type: :request do
  include ActiveJob::TestHelper

  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'U',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin', status: 'active')
  end
  let(:token)   { JsonWebToken.encode(user_id: user.id, company_id: company.id) }
  let(:headers) { { 'Authorization' => "Bearer #{token}", 'Content-Type' => 'application/json' } }

  def create_post(attrs)
    post '/api/v1/social-posts',
         params: { social_post: { platform: 'facebook', caption: 'Hello', status: 'draft' }.merge(attrs) }.to_json,
         headers: headers
    JSON.parse(response.body)
  end

  describe 'hashtags' do
    it 'comes back on load, so reopening a post does not show them as empty' do
      created = create_post(hashtags: %w[homes denver])

      get "/api/v1/social-posts/#{created['id']}", headers: headers

      expect(JSON.parse(response.body)['hashtags']).to eq(%w[homes denver])
    end
  end

  describe 'ad_settings' do
    let(:ad_settings) do
      { objective: 'LEAD_GENERATION', budget_min_per_day: 10,
        audience: { age_min: 25, age_max: 55, interests: %w[housing] },
        setup_steps: ['Pick an audience'] }
    end

    it 'is kept on create and returned on load' do
      created = create_post(ad_settings: ad_settings)

      get "/api/v1/social-posts/#{created['id']}", headers: headers
      body = JSON.parse(response.body)

      expect(body['ad_settings']).to include(
        'objective' => 'LEAD_GENERATION',
        'budget_min_per_day' => 10,
        'setup_steps' => ['Pick an audience']
      )
      expect(body['ad_settings']['audience']).to include('age_min' => 25, 'interests' => %w[housing])
    end

    it 'does not disturb the hashtags stored alongside it' do
      created = create_post(hashtags: %w[homes], ad_settings: ad_settings)

      patch "/api/v1/social-posts/#{created['id']}",
            params: { social_post: { ad_settings: { objective: 'TRAFFIC' } } }.to_json, headers: headers

      body = JSON.parse(response.body)
      expect(body['ad_settings']).to eq('objective' => 'TRAFFIC')
      expect(body['hashtags']).to eq(%w[homes])
    end
  end

  describe 'submitted_for_approval' do
    let!(:approver) do
      User.create!(email: "a-#{SecureRandom.hex(4)}@example.com", first_name: 'A', last_name: 'P',
                   password: 'Pass1234!', company_id: company.id, role: 'admin', status: 'active')
    end

    it 'emails the company admins and says how many were asked' do
      expect {
        created = create_post(submitted_for_approval: true)
        expect(created['approval_requested_count']).to eq(1)
      }.to have_enqueued_mail(SocialPostMailer, :approval_needed)
    end

    it 'sends nothing for a plain draft save' do
      expect {
        created = create_post({})
        expect(created).not_to have_key('approval_requested_count')
      }.not_to have_enqueued_mail(SocialPostMailer, :approval_needed)
    end

    it 'reports zero when there is no one else to ask' do
      approver.update!(status: 'inactive')

      created = nil
      expect { created = create_post(submitted_for_approval: true) }
        .not_to have_enqueued_mail(SocialPostMailer, :approval_needed)
      expect(created['approval_requested_count']).to eq(0)
    end
  end
end
