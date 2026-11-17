# frozen_string_literal: true

require 'rails_helper'
require 'rake'

# "Watch all" skips each video's intro and outro, so a video carries where they
# are. Search (the help sheet's Search tab) now returns videos too, each at the
# moment that answers the question.
RSpec.describe 'Training video intros and videos in search', type: :request do
  let(:company) { create(:company) }
  let(:dealer) do
    User.create!(email: "d-#{SecureRandom.hex(3)}@example.com", first_name: 'D', last_name: 'L', password: 'Pass1234!',
                 company_id: company.id, role: 'company_admin', status: 'active')
  end
  let(:platform) do
    User.create!(email: "p-#{SecureRandom.hex(3)}@example.com", first_name: 'P', last_name: 'A', password: 'Pass1234!',
                 company_id: company.id, role: 'platform_admin', status: 'active')
  end

  def h(user) = { 'Authorization' => "Bearer #{JsonWebToken.generate_access_token(user)}" }
  def body = JSON.parse(response.body)

  let!(:locations) do
    TrainingVideo.create!(title: 'Locations settings', module_key: 'settings', position: 1, is_published: true,
                          video_url: 'https://bucket.example/training-videos/locations.mp4', duration_seconds: 90,
                          intro_ends_at: 6, outro_starts_at: 80,
                          transcript: "0:04 Open the location list.\n0:25 Press Add Location to create a new one.",
                          chapters: [{ 'title' => 'Intro', 'start' => 0 }, { 'title' => 'Add a location', 'start' => 25, 'terms' => 'store, branch' }])
  end
  let!(:draft) do
    TrainingVideo.create!(title: 'Branch reports', module_key: 'settings', position: 2,
                          video_url: 'https://bucket.example/training-videos/branch.mp4', transcript: '0:03 Reports for each branch.')
  end

  describe 'intro and outro timings' do
    it 'go out with the video in the help center and on the public watch page' do
      TrainingVideo.enabled = true
      get '/api/v1/training_videos', headers: h(dealer)
      expect(body['videos'].first).to include('intro_ends_at' => 6, 'outro_starts_at' => 80)

      get "/api/public/training_videos/#{locations.share_token}"
      expect(body['video']).to include('intro_ends_at' => 6, 'outro_starts_at' => 80)
    end

    it 'are set and cleared by a platform admin in Knowledge admin' do
      put "/api/admin/training_videos/#{draft.id}", headers: h(platform), params: { video: { intro_ends_at: 9, outro_starts_at: 70 } }
      expect(response).to have_http_status(:ok), response.body
      expect(draft.reload).to have_attributes(intro_ends_at: 9, outro_starts_at: 70)

      put "/api/admin/training_videos/#{draft.id}", headers: h(platform), params: { video: { intro_ends_at: '' } }
      expect(draft.reload.intro_ends_at).to be_nil
    end

    it 'are copied to production by the video sync' do
      row = locations.as_api_json(admin: true).as_json.merge('uid' => SecureRandom.uuid, 'updated_at' => Time.current.iso8601,
                                                             'video_url' => nil, 'poster_url' => nil, 'captions_url' => nil)
      Guide::TrainingVideoSync.new(downloader: ->(*) { raise 'no download expected' }).apply([row])
      expect(TrainingVideo.find_by(uid: row['uid'])).to have_attributes(intro_ends_at: 6, outro_starts_at: 80)
    end
  end

  describe 'videos in search' do
    def search(q, user:) = Knowledge::SmartSearchService.new(q, user: user).search

    it 'returns a video at the moment that answers, when the tab is on' do
      TrainingVideo.enabled = true
      video = search('add another store', user: dealer).find { |r| r[:type] == 'video' }
      expect(video).to include(video_id: locations.id, start: 25, description: 'Add a location', module: 'settings', length: 90)
    end

    it 'returns no videos to a dealer while the tab is off, and drafts only to platform admins' do
      expect(search('branch', user: dealer).select { |r| r[:type] == 'video' }).to be_empty

      TrainingVideo.enabled = true
      expect(search('branch reports', user: dealer).filter_map { |r| r[:video_id] }).not_to include(draft.id)
      expect(search('branch reports', user: platform).filter_map { |r| r[:video_id] }).to include(draft.id)
    end

    it 'still returns articles when a video also matches' do
      TrainingVideo.enabled = true
      mod = Knowledge::Module.create!(key: 'settings', name: 'Settings', route: '/settings', is_active: true)
      Knowledge::Article.create!(knowledge_module: mod, title: 'Adding a store location', slug: 'add-store',
                                 content: 'Add another store from Locations.', is_published: true)
      types = search('add another store', user: dealer).map { |r| r[:type] }
      expect(types).to include('article', 'video')
    end
  end

  describe 'rake training_videos:prefill_intros' do
    before(:all) { Rails.application.load_tasks unless Rake::Task.task_defined?('training_videos:prefill_intros') }

    def run(write: false)
      ENV['WRITE'] = write ? '1' : nil
      task = Rake::Task['training_videos:prefill_intros']
      task.reenable
      expect { task.invoke }.to output.to_stdout
    ensure
      ENV.delete('WRITE')
    end

    let!(:short_intro) do
      TrainingVideo.create!(title: 'Short intro', chapters: [{ 'title' => 'Intro', 'start' => 0 }, { 'title' => 'Go', 'start' => 7 }])
    end
    let!(:long_first) do
      TrainingVideo.create!(title: 'Long first chapter', chapters: [{ 'title' => 'A', 'start' => 0 }, { 'title' => 'B', 'start' => 60 }])
    end

    it 'reports without writing, then saves only guesses of 45 seconds or less and never overwrites' do
      run
      expect(short_intro.reload.intro_ends_at).to be_nil

      run(write: true)
      expect(short_intro.reload.intro_ends_at).to eq(7)
      expect(long_first.reload.intro_ends_at).to be_nil
      expect(locations.reload.intro_ends_at).to eq(6)
      expect(locations.outro_starts_at).to eq(80)
    end
  end
end
