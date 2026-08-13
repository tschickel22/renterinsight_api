# frozen_string_literal: true

require 'rails_helper'

# The Page card counts comments live from Graph, while the inbox reads our own
# table, which the cron fills every 15 minutes. Someone who has just seen a
# comment appear on the card needs a way to pull it in now rather than waiting.
RSpec.describe 'Api::V1::SocialComments sync', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'U',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
  end
  let(:token)   { JsonWebToken.encode(user_id: user.id, company_id: company.id) }
  let(:headers) { { 'Authorization' => "Bearer #{token}", 'Content-Type' => 'application/json' } }

  let!(:integration) do
    company.facebook_integrations.create!(
      page_id: '55501', page_name: 'Test Page',
      page_access_token: 'page-token', status: 'active'
    )
  end

  let!(:post_record) do
    company.social_posts.create!(platform: 'facebook', status: 'published',
                                 caption: 'Hello', external_post_id: '55501_900',
                                 published_at: 1.hour.ago)
  end

  def graph_comment(id, name: 'Shopper', message: 'Is this still available?')
    {
      'id' => id, 'message' => message,
      'from' => { 'id' => '777', 'name' => name },
      'created_time' => 10.minutes.ago.iso8601
    }
  end

  it 'pulls a new comment in immediately' do
    allow(MetaGraphApi).to receive(:get_post_comments)
      .with('55501_900', 'page-token', limit: anything)
      .and_return({ 'data' => [graph_comment('c_1')] })

    post '/api/v1/social-comments/sync', headers: headers

    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    expect(body['new']).to eq(1)
    expect(company.social_comments.count).to eq(1)
    expect(company.social_comments.first.message).to eq('Is this still available?')
  end

  it 'does not duplicate a comment already synced' do
    allow(MetaGraphApi).to receive(:get_post_comments)
      .and_return({ 'data' => [graph_comment('c_1')] })

    2.times { post '/api/v1/social-comments/sync', headers: headers }

    expect(company.social_comments.count).to eq(1)
    expect(JSON.parse(response.body)['new']).to eq(0)
  end

  it 'reports an expired token instead of silently syncing nothing' do
    allow(MetaGraphApi).to receive(:get_post_comments)
      .and_raise(MetaGraphApi::ExpiredTokenError.new('token expired'))

    post '/api/v1/social-comments/sync', headers: headers

    expect(response).to have_http_status(:unprocessable_entity)
    expect(JSON.parse(response.body)['error']).to match(/token expired/i)
    expect(integration.reload.status).to eq('expired')
  end

  it 'reports rate limiting rather than looking like there is nothing new' do
    allow(MetaGraphApi).to receive(:get_post_comments)
      .and_raise(MetaGraphApi::RateLimitError.new('slow down'))

    post '/api/v1/social-comments/sync', headers: headers

    expect(response).to have_http_status(:too_many_requests)
  end

  it 'tells the user when no page is connected' do
    integration.update!(status: 'expired')

    post '/api/v1/social-comments/sync', headers: headers

    expect(response).to have_http_status(:unprocessable_entity)
    expect(JSON.parse(response.body)['error']).to match(/No Facebook page connected/)
  end

  it 'never reads another company post' do
    other = Company.create!(name: "Other-#{SecureRandom.hex(3)}")
    other.social_posts.create!(platform: 'facebook', status: 'published',
                               caption: 'Theirs', external_post_id: '55501_888',
                               published_at: 1.hour.ago)

    expect(MetaGraphApi).not_to receive(:get_post_comments).with('55501_888', anything, any_args)
    allow(MetaGraphApi).to receive(:get_post_comments).and_return({ 'data' => [] })

    post '/api/v1/social-comments/sync', headers: headers

    expect(response).to have_http_status(:ok)
  end
end
