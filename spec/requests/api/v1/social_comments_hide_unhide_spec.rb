# frozen_string_literal: true

require 'rails_helper'

# Hiding a comment used to be a one way door. `active` means status 'active',
# hide sets 'hidden', and every list used `active`, so the comment vanished
# with no way to find it again. There was no unhide endpoint either, even
# though MetaGraphApi.unhide_comment already existed.
RSpec.describe 'Api::V1::SocialComments hide and unhide', type: :request do
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

  describe 'hiding' do
    it 'hides on Facebook and marks the row hidden' do
      expect(MetaGraphApi).to receive(:hide_comment).with('c_1', 'page-token').and_return({ 'success' => true })

      post "/api/v1/social-comments/#{comment.id}/hide", headers: headers

      expect(response).to have_http_status(:ok)
      expect(comment.reload.status).to eq('hidden')
    end

    # Marking it hidden anyway told the user a comment was hidden while it was
    # still public on the Page.
    it 'leaves the comment alone when Facebook refuses' do
      allow(MetaGraphApi).to receive(:hide_comment)
        .and_raise(MetaGraphApi::Error.new('(#200) Permissions error'))

      post "/api/v1/social-comments/#{comment.id}/hide", headers: headers

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)['error']).to match(/Permissions error/)
      expect(comment.reload.status).to eq('active')
    end

    it 'does not claim to hide anything with no page connected' do
      integration.update!(status: 'expired')

      post "/api/v1/social-comments/#{comment.id}/hide", headers: headers

      expect(response).to have_http_status(:unprocessable_entity)
      expect(comment.reload.status).to eq('active')
    end
  end

  describe 'unhiding' do
    before { comment.update!(status: 'hidden') }

    it 'unhides on Facebook and restores the row' do
      expect(MetaGraphApi).to receive(:unhide_comment).with('c_1', 'page-token').and_return({ 'success' => true })

      post "/api/v1/social-comments/#{comment.id}/unhide", headers: headers

      expect(response).to have_http_status(:ok)
      expect(comment.reload.status).to eq('active')
    end

    it 'keeps the row hidden when Facebook refuses' do
      allow(MetaGraphApi).to receive(:unhide_comment)
        .and_raise(MetaGraphApi::Error.new('(#200) Permissions error'))

      post "/api/v1/social-comments/#{comment.id}/unhide", headers: headers

      expect(response).to have_http_status(:unprocessable_entity)
      expect(comment.reload.status).to eq('hidden')
    end
  end

  describe 'finding a hidden comment again' do
    before { comment.update!(status: 'hidden') }

    # It used to drop out of the default list, so a reload took the Unhide
    # button away with it and the comment was gone for good.
    it 'stays in the default list so it can still be unhidden' do
      get '/api/v1/social-comments', headers: headers

      body = JSON.parse(response.body)['comments']
      expect(body.map { |c| c['id'] }).to eq([comment.id])
      expect(body.first['status']).to eq('hidden')
    end

    it 'is left out of Unread, since a hidden comment is not awaiting a reply' do
      get '/api/v1/social-comments?unread=true', headers: headers

      expect(JSON.parse(response.body)['comments']).to be_empty
    end

    it 'does not count towards unread' do
      get '/api/v1/social-comments', headers: headers

      expect(JSON.parse(response.body)['meta']['unread_count']).to eq(0)
    end

    it 'is reachable with status=hidden, so it can be unhidden' do
      get '/api/v1/social-comments?status=hidden', headers: headers

      expect(response).to have_http_status(:ok)
      ids = JSON.parse(response.body)['comments'].map { |c| c['id'] }
      expect(ids).to eq([comment.id])
    end

    it 'does not show a deleted comment among the hidden ones' do
      comment.update!(status: 'deleted', is_deleted: true)

      get '/api/v1/social-comments?status=hidden', headers: headers

      expect(JSON.parse(response.body)['comments']).to be_empty
    end

    it 'keeps a deleted comment out of the default list too' do
      comment.update!(status: 'deleted', is_deleted: true)

      get '/api/v1/social-comments', headers: headers

      expect(JSON.parse(response.body)['comments']).to be_empty
    end
  end
end
