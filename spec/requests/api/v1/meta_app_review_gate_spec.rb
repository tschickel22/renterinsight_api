# frozen_string_literal: true

require 'rails_helper'

# TEMPORARY. Delete with MetaAppReview once Meta approves
# pages_manage_engagement and read_insights.
#
# A dealer's connection carries neither permission until then, so every call
# that needs one fails at Graph with "(#200) ...". The gate refuses before
# Graph is called and tells the frontend which controls to draw.
RSpec.describe 'Meta App Review gate', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  # A dealer's own admin: the gate applies to them. Platform admins are exempt.
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'U',
                 password: 'Pass1234!', company_id: company.id, role: 'company_admin')
  end
  let(:token)   { JsonWebToken.encode(user_id: user.id, company_id: company.id) }
  let(:headers) { { 'Authorization' => "Bearer #{token}", 'Content-Type' => 'application/json' } }

  let!(:integration) do
    company.facebook_integrations.create!(
      page_id: '55501', page_name: 'Test Page',
      page_access_token: 'page-token', status: 'active'
    )
  end

  let!(:social_post) do
    company.social_posts.create!(platform: 'facebook', status: 'published',
                                 caption: 'Hello', external_post_id: '55501_900',
                                 published_at: 1.hour.ago)
  end

  let!(:comment) do
    company.social_comments.create!(
      social_post: social_post, external_comment_id: 'c_1',
      external_post_id: '55501_900', platform: 'facebook',
      author_name: 'Shopper', message: 'Is this available?',
      status: 'active', commented_at: 10.minutes.ago
    )
  end

  around do |example|
    saved = ENV.to_h.slice('META_PERMISSIONS_AWAITING_REVIEW', 'META_REVIEW_COMPANY_IDS')
    ENV.delete('META_PERMISSIONS_AWAITING_REVIEW')
    ENV.delete('META_REVIEW_COMPANY_IDS')
    example.run
  ensure
    ENV.delete('META_PERMISSIONS_AWAITING_REVIEW')
    ENV.delete('META_REVIEW_COMPANY_IDS')
    saved.each { |k, v| ENV[k] = v }
  end

  def pending_refusal?
    response.status == 422 && JSON.parse(response.body)['code'] == 'meta_permission_pending'
  end

  describe 'while both permissions await review (the default)' do
    it 'refuses a reply without calling Graph' do
      expect(MetaGraphApi).not_to receive(:reply_to_comment)

      post "/api/v1/social-comments/#{comment.id}/reply", params: { message: 'Yes!' }.to_json, headers: headers

      expect(pending_refusal?).to be true
      expect(company.social_comments.count).to eq(1)
    end

    it 'refuses hide, unhide and delete without touching the row' do
      expect(MetaGraphApi).not_to receive(:hide_comment)
      expect(MetaGraphApi).not_to receive(:unhide_comment)
      expect(MetaGraphApi).not_to receive(:delete_comment)

      post "/api/v1/social-comments/#{comment.id}/hide", headers: headers
      expect(pending_refusal?).to be true

      post "/api/v1/social-comments/#{comment.id}/unhide", headers: headers
      expect(pending_refusal?).to be true

      delete "/api/v1/social-comments/#{comment.id}", headers: headers
      expect(pending_refusal?).to be true

      expect(comment.reload.status).to eq('active')
    end

    it 'refuses the Page like' do
      expect(MetaGraphApi).not_to receive(:like_object)

      post '/api/v1/brand-health/posts/55501_900/like', headers: headers

      expect(pending_refusal?).to be true
    end

    it 'tells the comments list to hide moderation controls' do
      get '/api/v1/social-comments', headers: headers

      expect(JSON.parse(response.body)['capabilities']).to eq('engagement' => false, 'insights' => false)
    end

    it 'skips Page insights and says so, rather than reporting zeros' do
      allow(MetaGraphApi).to receive(:get) do |path, *_|
        raise 'insights must not be requested' if path.end_with?('/insights')

        path == '/55501' ? { 'id' => '55501', 'name' => 'Test Page', 'fan_count' => 10 } : { 'data' => [] }
      end

      get '/api/v1/brand-health', headers: headers

      body = JSON.parse(response.body)
      expect(response).to have_http_status(:ok)
      expect(body['insights'].keys).to eq(['posts_30d'])
      expect(body['capabilities']).to eq('engagement' => false, 'insights' => false)
    end
  end

  describe 'lifting it' do
    it 'reads the awaiting list from ENV, so approval needs no deploy' do
      ENV['META_PERMISSIONS_AWAITING_REVIEW'] = 'read_insights'
      expect(MetaAppReview.capabilities(company)).to eq(engagement: true, insights: false)

      ENV['META_PERMISSIONS_AWAITING_REVIEW'] = ''
      expect(MetaAppReview.capabilities(company)).to eq(engagement: true, insights: true)
    end

    it 'lifts it for a named review tenant only' do
      other = Company.create!(name: "Other-#{SecureRandom.hex(4)}")
      ENV['META_REVIEW_COMPANY_IDS'] = company.id.to_s

      expect(MetaAppReview.engagement?(company)).to be true
      expect(MetaAppReview.engagement?(other)).to be false
    end

    # So the resubmission can be recorded from any tenant without an ENV change.
    it 'is lifted for a platform admin' do
      admin = User.create!(email: "a-#{SecureRandom.hex(4)}@example.com", first_name: 'P', last_name: 'A',
                           password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
      admin_headers = headers.merge('Authorization' => "Bearer #{JsonWebToken.encode(user_id: admin.id, company_id: company.id)}")
      expect(MetaGraphApi).to receive(:reply_to_comment).and_return({ 'id' => 'c_2' })

      get '/api/v1/social-comments', headers: admin_headers
      expect(JSON.parse(response.body)['capabilities']).to eq('engagement' => true, 'insights' => true)

      post "/api/v1/social-comments/#{comment.id}/reply", params: { message: 'Yes!' }.to_json, headers: admin_headers
      expect(response).to have_http_status(:created)
    end

    it 'is lifted for a super admin but not for a company admin' do
      expect(MetaAppReview.engagement?(company, user: User.new(role: 'super_admin'))).to be true
      expect(MetaAppReview.engagement?(company, user: User.new(role: 'company_admin'))).to be false
    end

    it 'lets a review tenant reply' do
      ENV['META_REVIEW_COMPANY_IDS'] = company.id.to_s
      expect(MetaGraphApi).to receive(:reply_to_comment).and_return({ 'id' => 'c_2' })

      post "/api/v1/social-comments/#{comment.id}/reply", params: { message: 'Yes!' }.to_json, headers: headers

      expect(response).to have_http_status(:created)
    end
  end
end
