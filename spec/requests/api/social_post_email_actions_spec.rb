# frozen_string_literal: true

require 'rails_helper'

# The approval email carries approve, decline and skip links. They used to act
# on GET, so an email security scanner following the links actioned the post
# before the recipient saw it: on 2026-08-28 a scanner hit all three for post 69
# from three IPs within one second, skip won, and the real approval hours later
# was told the post had "already been failed".
RSpec.describe 'Social post email actions', type: :request do
  let(:company) { create(:company, use_rbac_system: false) }
  let(:post_record) do
    SocialPost.create!(company_id: company.id, status: 'draft', platform: 'facebook',
                       caption: 'How many hours does your team spend this week')
  end

  def token_for(action, id = post_record.id)
    SocialPostMailer.signed_action_token(post_id: id, action: action)
  end

  describe 'a scanner fetching the links' do
    %w[approve decline skip].each do |action|
      path = { 'approve' => 'email_approve', 'decline' => 'email_decline', 'skip' => 'skip' }[action]

      it "leaves the post untouched when #{action} is fetched with GET" do
        get "/api/v1/social-posts/#{post_record.id}/#{path}?token=#{token_for(action)}"

        expect(response).to have_http_status(:ok)
        expect(post_record.reload.status).to eq('draft')
      end

      it "offers a button rather than acting, for #{action}" do
        get "/api/v1/social-posts/#{post_record.id}/#{path}?token=#{token_for(action)}"

        expect(response.body).to include('<form method="post"')
        expect(response.body).to include('Nothing has changed yet')
      end
    end
  end

  describe 'a person pressing the button' do
    it 'approves on POST' do
      post "/api/v1/social-posts/#{post_record.id}/email_approve", params: { token: token_for('approve') }

      expect(response).to have_http_status(:ok)
      expect(post_record.reload.status).to eq('approved')
      expect(post_record.nurture_approved).to be(true)
    end

    it 'declines on POST' do
      post "/api/v1/social-posts/#{post_record.id}/email_decline", params: { token: token_for('decline') }

      expect(post_record.reload.status).to eq('failed')
    end

    it 'skips on POST' do
      post "/api/v1/social-posts/#{post_record.id}/skip", params: { token: token_for('skip') }

      expect(post_record.reload.status).to eq('failed')
    end
  end

  describe 'a post that is no longer a draft' do
    it 'explains what happened in words that fit the status' do
      post_record.update!(status: 'failed')

      get "/api/v1/social-posts/#{post_record.id}/email_approve?token=#{token_for('approve')}"

      expect(response.body).to include('already declined or skipped')
      expect(response.body).not_to include('already been failed')
    end

    it 'says approved when it was approved' do
      post_record.update!(status: 'approved')

      get "/api/v1/social-posts/#{post_record.id}/email_approve?token=#{token_for('approve')}"

      expect(response.body).to include('already been approved')
    end
  end

  describe 'token guards still hold' do
    it 'rejects a token minted for a different action' do
      post "/api/v1/social-posts/#{post_record.id}/email_approve", params: { token: token_for('decline') }

      expect(response.body).to include('Invalid action token')
      expect(post_record.reload.status).to eq('draft')
    end

    it 'rejects a token minted for a different post' do
      post "/api/v1/social-posts/#{post_record.id}/email_approve", params: { token: token_for('approve', post_record.id + 999) }

      expect(response.body).to include('does not match')
      expect(post_record.reload.status).to eq('draft')
    end
  end
end
