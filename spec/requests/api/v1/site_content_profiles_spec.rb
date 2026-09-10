# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Api::V1::SiteContentProfiles', type: :request do
  describe 'access boundary' do
    it 'exposes by_token publicly and guards everything else' do
      routes = Rails.application.routes.routes.map do |r|
        [r.defaults[:controller], r.defaults[:action]]
      end.uniq

      actions = routes.select { |c, _| c == 'api/v1/site_content_profiles' }.map(&:last)
      expect(actions).to include('by_token', 'create', 'index', 'show', 'destroy', 'rotate_preview_token')
    end

    # Two actions sit outside the controller's blanket JWT guard, for opposite
    # reasons: by_token is public by design, and import authenticates itself so
    # it can take an API key as well as a login. Nothing else may.
    it 'skips the blanket authentication only where an action guards itself' do
      source = File.read(Rails.root.join('app/controllers/api/v1/site_content_profiles_controller.rb'))

      expect(source).to match(/skip_before_action :authenticate, only: %i\[by_token import\]/)
      expect(source).to match(/before_action :require_platform_admin!, except: %i\[by_token import\]/)
      # import is not left open: it has its own guard.
      expect(source).to match(/before_action :authorize_import!, only: \[:import\]/)
    end

    # The guard is worth checking as behaviour and not only as source, since the
    # source assertions above cannot tell a guard from a comment.
    it 'still refuses an unauthenticated import' do
      post '/api/v1/site_content_profiles/import', params: { profile: { brand: {} } }

      expect(response).to have_http_status(:unauthorized)
    end

    it 'still refuses an unauthenticated index' do
      get '/api/v1/site_content_profiles'

      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe 'GET /api/v1/site_content_profiles/by_token/:token' do
    it 'returns 404 for an unknown token' do
      get '/api/v1/site_content_profiles/by_token/nope'
      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'SiteContentProfile#shareable?' do
    let(:profile) { SiteContentProfile.new(status: 'ready', preview_token: 'abc') }

    it 'is shareable when ready with a live token' do
      expect(profile).to be_shareable
    end

    it 'is not shareable before the scan finishes' do
      profile.status = 'pending'
      expect(profile).not_to be_shareable
    end

    it 'is not shareable once expired' do
      profile.preview_expires_at = 1.hour.ago
      expect(profile).not_to be_shareable
    end

    it 'is not shareable after the token is cleared' do
      profile.preview_token = nil
      expect(profile).not_to be_shareable
    end

    it 'generates a hard-to-guess token' do
      expect(SiteContentProfile.new_preview_token.length).to be >= 24
      expect(SiteContentProfile.new_preview_token).not_to eq(SiteContentProfile.new_preview_token)
    end
  end
end
