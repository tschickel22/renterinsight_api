# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Training video drafts and the public series', type: :request do
  let(:key) { 'test-upload-key' }
  let(:headers) { { 'X-Training-Upload-Key' => key } }
  let(:video_params) do
    { video: { title: 'Users settings', description: 'd', module_key: 'company_settings', position: 5,
               is_published: true, share_enabled: true, share_token: 'stolen',
               chapters: [{ title: 'Find it', start: 4, terms: 'staff' }], covers: { routes: ['/settings'], markers: ['settings-tab:users'] } } }
  end
  let(:body) { JSON.parse(response.body) }

  before { Setting.set('Platform', PlatformSetting::PLATFORM_SCOPE_ID, 'training_upload_token_sha256', Digest::SHA256.hexdigest(key)) }

  describe 'upsert' do
    it 'makes an unpublished draft with sharing off, whatever it is sent, keeping search words' do
      put '/api/public/training_video_drafts/users-settings', headers: headers, params: video_params
      expect(response).to have_http_status(:ok), response.body
      video = TrainingVideo.find_by!(slug: 'users-settings')
      expect(video).to have_attributes(is_published: false, share_enabled: false, module_key: 'company_settings', position: 5)
      expect(video.share_token).not_to eq('stolen')
      expect(video.chapters.first['terms']).to eq('staff')
      expect(video.covers['markers']).to eq(['settings-tab:users'])
    end

    it 'replaces a draft without making a second one' do
      2.times { put '/api/public/training_video_drafts/users-settings', headers: headers, params: video_params }
      expect(TrainingVideo.where(slug: 'users-settings').count).to eq(1)
    end

    it 'turns sharing off on a draft that had it on' do
      video = TrainingVideo.create!(title: 'Users settings', slug: 'users-settings', share_enabled: true)
      put '/api/public/training_video_drafts/users-settings', headers: headers, params: video_params
      expect(video.reload.share_enabled).to be(false)
    end

    it 'will not touch a published video' do
      video = TrainingVideo.create!(title: 'Old', slug: 'users-settings', is_published: true, video_url: 'https://x/v.mp4')
      put '/api/public/training_video_drafts/users-settings', headers: headers, params: video_params
      expect(response).to have_http_status(:conflict)
      expect(video.reload).to have_attributes(title: 'Old', is_published: true)
    end
  end

  describe 'who it answers' do
    it 'refuses a missing or wrong key' do
      put '/api/public/training_video_drafts/users-settings', params: video_params
      expect(response).to have_http_status(:unauthorized)
      put '/api/public/training_video_drafts/users-settings', headers: { 'X-Training-Upload-Key' => 'nope' }, params: video_params
      expect(response).to have_http_status(:unauthorized)
      expect(TrainingVideo.exists?(slug: 'users-settings')).to be(false)
    end

    it 'refuses everyone where no key is stored' do
      Setting.where(scope_type: 'Platform', key: 'training_upload_token_sha256').delete_all
      Rails.cache.clear
      put '/api/public/training_video_drafts/users-settings', headers: { 'X-Training-Upload-Key' => '' }, params: video_params
      expect(response).to have_http_status(:unauthorized)
    end

    it 'refuses on a server that copies its help from another (production), even with the key' do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with('GUIDE_SYNC_SOURCE_URL').and_return('https://staging.example')
      put '/api/public/training_video_drafts/users-settings', headers: headers, params: video_params
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe 'files' do
    let(:file) { Rack::Test::UploadedFile.new(StringIO.new("WEBVTT\n\n1\n00:00:04.000 --> 00:00:06.000\nOpen the list.\n"), 'text/vtt', original_filename: 'x.vtt') }

    before { TrainingVideo.create!(title: 'Users settings', slug: 'users-settings') }

    it 'stores captions and fills the transcript' do
      service = instance_double(S3UploadService, upload: { url: 'https://x/c.vtt', key: 'k', size: 1 })
      allow(S3UploadService).to receive(:new).and_return(service)
      post '/api/public/training_video_drafts/users-settings/files', headers: headers, params: { kind: 'captions', file: file }
      expect(response).to have_http_status(:ok), response.body
      video = TrainingVideo.find_by!(slug: 'users-settings')
      expect(video.captions_url).to eq('https://x/c.vtt')
      expect(video.transcript).to include('Open the list.')
    end

    it 'refuses the wrong kind of file' do
      post '/api/public/training_video_drafts/users-settings/files', headers: headers, params: { kind: 'video', file: file }
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe 'public series' do
    it 'shows published videos only' do
      TrainingVideo.create!(title: 'Live', module_key: 'company_settings', is_published: true, share_enabled: true, video_url: 'https://x/a.mp4')
      TrainingVideo.create!(title: 'Draft', module_key: 'company_settings', is_published: false, share_enabled: true, video_url: 'https://x/b.mp4')
      get '/api/public/training_videos/series/company_settings'
      expect(body['videos'].map { |v| v['title'] }).to eq(['Live'])
    end

    it 'is not available when every video is a draft' do
      TrainingVideo.create!(title: 'Draft', module_key: 'company_settings', share_enabled: true, video_url: 'https://x/b.mp4')
      get '/api/public/training_videos/series/company_settings'
      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'copying to production' do
    let(:row) { { 'uid' => SecureRandom.uuid, 'title' => 'Draft', 'slug' => 'draft', 'updated_at' => Time.current.iso8601, 'is_published' => false } }

    it 'leaves a new draft behind' do
      expect(Guide::TrainingVideoSync.new(downloader: ->(*) {}).apply([row])).to eq(0)
      expect(TrainingVideo.exists?(uid: row['uid'])).to be(false)
    end

    it 'still hides a video that was unpublished on staging after it was copied' do
      copy = TrainingVideo.create!(title: 'Was live', uid: row['uid'], is_published: true, source_files: { 'updated_at' => 'old' })
      Guide::TrainingVideoSync.new(downloader: ->(*) {}).apply([row])
      expect(copy.reload.is_published).to be(false)
    end
  end
end
