# frozen_string_literal: true

require 'rails_helper'

# A published SocialPost is two things at once: a row here and a live story on
# the Facebook Page. Deleting or editing only the row leaves the Page saying
# something the app no longer shows, with nothing to reveal the drift — which
# is exactly what happened to a test post on staging.
RSpec.describe 'Api::V1::SocialPosts remote sync', type: :request do
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

  def create_post(**attrs)
    company.social_posts.create!({
      platform: 'facebook', status: 'published', caption: 'Original caption',
      external_post_id: '55501_99901', published_at: Time.current
    }.merge(attrs))
  end

  # ------------------------------------------------------------------
  # Delete
  # ------------------------------------------------------------------
  describe 'DELETE /api/v1/social-posts/:id' do
    it 'removes the live Page post before soft-deleting the row' do
      post_record = create_post

      expect(MetaGraphApi).to receive(:delete_page_post)
        .with('55501_99901', 'page-token').and_return({ 'success' => true })

      delete "/api/v1/social-posts/#{post_record.id}", headers: headers

      expect(response).to have_http_status(:no_content)
      expect(post_record.reload.is_deleted).to be true
    end

    it 'keeps the row when Facebook refuses the delete, so the two cannot silently diverge' do
      post_record = create_post

      allow(MetaGraphApi).to receive(:delete_page_post)
        .and_raise(MetaGraphApi::Error.new('Insufficient permission'))

      delete "/api/v1/social-posts/#{post_record.id}", headers: headers

      expect(response).to have_http_status(:unprocessable_entity)
      body = JSON.parse(response.body)
      expect(body['remote_delete_failed']).to be true
      expect(body['error']).to match(/Insufficient permission/)
      expect(post_record.reload.is_deleted).to be_falsey
    end

    it 'soft-deletes anyway when the caller forces it' do
      post_record = create_post

      allow(MetaGraphApi).to receive(:delete_page_post)
        .and_raise(MetaGraphApi::Error.new('Insufficient permission'))

      delete "/api/v1/social-posts/#{post_record.id}?force=true", headers: headers

      expect(response).to have_http_status(:no_content)
      expect(post_record.reload.is_deleted).to be true
    end

    it 'treats an already-removed Page post as success rather than making the user force it' do
      post_record = create_post

      allow(MetaGraphApi).to receive(:delete_page_post)
        .and_raise(MetaGraphApi::NotFoundError.new('does not exist'))

      delete "/api/v1/social-posts/#{post_record.id}", headers: headers

      expect(response).to have_http_status(:no_content)
      expect(post_record.reload.is_deleted).to be true
    end

    it 'does not call Facebook for a draft that was never published' do
      post_record = create_post(status: 'draft', external_post_id: nil, published_at: nil)

      expect(MetaGraphApi).not_to receive(:delete_page_post)

      delete "/api/v1/social-posts/#{post_record.id}", headers: headers

      expect(response).to have_http_status(:no_content)
      expect(post_record.reload.is_deleted).to be true
    end

    it 'refuses a published Instagram post, which Graph cannot delete' do
      post_record = create_post(platform: 'instagram', external_post_id: 'ig_123')

      delete "/api/v1/social-posts/#{post_record.id}", headers: headers

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)['error']).to match(/Instagram/)
      expect(post_record.reload.is_deleted).to be_falsey
    end
  end

  # ------------------------------------------------------------------
  # Edit
  # ------------------------------------------------------------------
  describe 'PATCH /api/v1/social-posts/:id' do
    it 'pushes an edited caption to the live Page post' do
      post_record = create_post

      expect(MetaGraphApi).to receive(:update_page_post_message)
        .with('55501_99901', 'page-token', message: 'Rewritten caption')
        .and_return({ 'success' => true })

      patch "/api/v1/social-posts/#{post_record.id}", headers: headers,
            params: { social_post: { caption: 'Rewritten caption' } }.to_json

      expect(response).to have_http_status(:ok)
      expect(post_record.reload.caption).to eq('Rewritten caption')
    end

    it 'sends hashtag edits too, since they are part of the message Facebook shows' do
      post_record = create_post(generation_context: { 'hashtags' => ['oldtag'] })

      expect(MetaGraphApi).to receive(:update_page_post_message)
        .with('55501_99901', 'page-token', message: "Original caption\n\n#newtag")
        .and_return({ 'success' => true })

      patch "/api/v1/social-posts/#{post_record.id}", headers: headers,
            params: { social_post: { hashtags: ['newtag'] } }.to_json

      expect(response).to have_http_status(:ok)
    end

    it 'does not save the local edit when Facebook rejects it' do
      post_record = create_post

      allow(MetaGraphApi).to receive(:update_page_post_message)
        .and_raise(MetaGraphApi::Error.new('Post is not editable'))

      patch "/api/v1/social-posts/#{post_record.id}", headers: headers,
            params: { social_post: { caption: 'Rewritten caption' } }.to_json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)['error']).to match(/Post is not editable/)
      expect(post_record.reload.caption).to eq('Original caption')
    end

    it 'refuses a caption edit on a photo post, whose text Facebook freezes at publish' do
      post_record = create_post(image_urls: ['https://example.com/a.jpg'])

      expect(MetaGraphApi).not_to receive(:update_page_post_message)

      patch "/api/v1/social-posts/#{post_record.id}", headers: headers,
            params: { social_post: { caption: 'Rewritten caption' } }.to_json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)['error']).to match(/photo or video/)
      expect(post_record.reload.caption).to eq('Original caption')
    end

    # The compose form re-sends the whole payload on every save, so a post
    # stored with a NULL image_urls comes back as []. That is not an edit.
    it 'does not mistake a re-sent empty image list for changing the images' do
      post_record = create_post(image_urls: nil)

      expect(MetaGraphApi).to receive(:update_page_post_message)
        .with('55501_99901', 'page-token', message: 'Rewritten caption')
        .and_return({ 'success' => true })

      patch "/api/v1/social-posts/#{post_record.id}", headers: headers,
            params: { social_post: { caption: 'Rewritten caption', image_urls: [] } }.to_json

      expect(response).to have_http_status(:ok)
      expect(post_record.reload.caption).to eq('Rewritten caption')
    end

    it 'refuses to swap the images of a published post' do
      post_record = create_post(image_urls: ['https://example.com/a.jpg'])

      patch "/api/v1/social-posts/#{post_record.id}", headers: headers,
            params: { social_post: { image_urls: ['https://example.com/b.jpg'] } }.to_json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)['error']).to match(/images/)
      expect(post_record.reload.image_urls).to eq(['https://example.com/a.jpg'])
    end

    # Bookkeeping fields describe our records, not the story on the Page, so
    # they must stay editable — otherwise a published photo post could never be
    # attributed to a unit.
    it 'edits a field Facebook never sees without calling Graph at all' do
      post_record = create_post(image_urls: ['https://example.com/a.jpg'])

      expect(MetaGraphApi).not_to receive(:update_page_post_message)

      patch "/api/v1/social-posts/#{post_record.id}", headers: headers,
            params: { social_post: { utm_campaign: 'spring-sale' } }.to_json

      expect(response).to have_http_status(:ok)
      expect(post_record.reload.utm_campaign).to eq('spring-sale')
    end

    it 'edits a draft freely, with no Facebook round trip' do
      post_record = create_post(status: 'draft', external_post_id: nil, published_at: nil)

      expect(MetaGraphApi).not_to receive(:update_page_post_message)

      patch "/api/v1/social-posts/#{post_record.id}", headers: headers,
            params: { social_post: { caption: 'Draft rewrite', image_urls: ['https://example.com/b.jpg'] } }.to_json

      expect(response).to have_http_status(:ok)
      expect(post_record.reload.caption).to eq('Draft rewrite')
    end
  end
end
