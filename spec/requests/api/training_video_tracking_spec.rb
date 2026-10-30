# frozen_string_literal: true

require 'rails_helper'

# E88 round 2: progress, required training, series links, the assistant's
# video search, and production copying staging's videos.
RSpec.describe 'Training video tracking and required training', type: :request do
  let(:company) { create(:company) }
  let(:other_company) { create(:company) }
  def make_user(role, co = company)
    User.create!(email: "#{role}-#{SecureRandom.hex(3)}@example.com", first_name: role.titleize, last_name: 'X', password: 'Pass1234!',
                 company_id: co.id, role: role, status: 'active')
  end
  let(:admin) { make_user('company_admin') }
  let(:rep) { make_user('user') }
  def h(user) = { 'Authorization' => "Bearer #{JsonWebToken.generate_access_token(user)}" }
  def body = JSON.parse(response.body)

  let!(:video) do
    TrainingVideo.create!(title: 'Getting bids', module_key: 'projects', position: 1, is_published: true, duration_seconds: 100,
                          video_url: 'https://bucket.example/a.mp4', chapters: [{ 'title' => 'Ask', 'start' => 0 }, { 'title' => 'Award', 'start' => 40 }],
                          transcript: "0:05 Pick the contractors to ask.\n0:42 Award the winning bid with a note.")
  end
  let!(:second) do
    TrainingVideo.create!(title: 'Review Updates', module_key: 'projects', position: 2, is_published: true, duration_seconds: 60,
                          video_url: 'https://bucket.example/b.mp4')
  end

  before { TrainingVideo.enabled = true }

  it 'records how far a person got and marks the video watched at 90 percent' do
    post "/api/v1/training_videos/#{video.id}/progress", headers: h(rep), params: { position: 30, seconds: 30, started: true }
    expect(body['progress']).to include('furthest_seconds' => 30, 'completed' => false)
    post "/api/v1/training_videos/#{video.id}/progress", headers: h(rep), params: { position: 91, seconds: 60 }
    expect(body['progress']['completed']).to be(true)

    get '/api/v1/training_videos', headers: h(rep)
    mine = body['videos'].find { |v| v['id'] == video.id }
    expect(mine['progress']['completed']).to be(true)
  end

  it 'lets a company admin require videos, pick them for new users, and see who is done' do
    post '/api/v1/training_assignments', headers: h(rep), params: { user_ids: [rep.id], video_ids: [video.id] }
    expect(response).to have_http_status(:forbidden)

    outsider = make_user('user', other_company)
    post '/api/v1/training_assignments', headers: h(admin), params: { user_ids: [rep.id, outsider.id], video_ids: [video.id], due_on: '2026-11-15' }
    expect(body['assigned']).to eq(1)
    expect(TrainingAssignment.where(user_id: outsider.id)).to be_empty

    get '/api/v1/training_videos', headers: h(rep)
    expect(body['videos'].find { |v| v['id'] == video.id }['assigned']).to eq('due_on' => '2026-11-15')

    put '/api/v1/training_assignments/new_users', headers: h(admin), params: { video_ids: [second.id] }
    newbie = make_user('user')
    expect(TrainingAssignment.where(user_id: newbie.id).pluck(:training_video_id, :source)).to eq([[second.id, 'new_user']])

    TrainingVideoView.record!(user: rep, video: video, position: 95, seconds: 95)
    get '/api/v1/training_assignments', headers: h(admin)
    row = body['users'].find { |u| u['id'] == rep.id }
    expect(row['assignments'].first).to include('video_id' => video.id)
    expect(row['assignments'].first['completed_at']).to be_present
    expect(body['users'].map { |u| u['id'] }).not_to include(outsider.id)
  end

  it 'plays a whole area as one series by public link, and counts public plays' do
    get '/api/public/training_videos/series/projects'
    expect(body['videos'].map { |v| v['title'] }).to eq(['Getting bids', 'Review Updates'])
    expect(body['videos'].first['token']).to eq(video.share_token)

    post "/api/public/training_videos/#{video.share_token}/play"
    expect(video.reload.public_views).to eq(1)
  end

  it 'finds the moment in a video that answers a question' do
    found = TrainingVideo.search('how do I award a bid')
    expect(found.first.first).to eq(video)
    expect(found.first.last).to eq(start: 41, label: 'Award')
  end

  it 'turns captions into a transcript with times' do
    vtt = "WEBVTT\n\n1\n00:00:05.200 --> 00:00:08.000\nPick the contractors.\n\n2\n00:01:02.000 --> 00:01:04.000\nAward it."
    expect(TrainingVideo.transcript_from_vtt(vtt)).to eq("0:05 Pick the contractors.\n1:02 Award it.")
  end

  it 'copies staging videos to production, files into its own bucket, only when they changed' do
    s3 = instance_double(S3UploadService)
    allow(S3UploadService).to receive(:new).and_return(s3)
    allow(s3).to receive(:upload) { |_f, key:| { url: "https://prod.example/#{key}", key: key, size: 10 } }
    downloads = []
    sync = Guide::TrainingVideoSync.new(downloader: ->(url, io) { downloads << url; io.write('x'); true })
    remote = {
      'uid' => SecureRandom.uuid, 'slug' => 'job-costs', 'share_token' => 'tok123456789', 'title' => 'Job costs',
      'module_key' => 'projects', 'position' => 6, 'is_published' => false, 'share_enabled' => true, 'chapters' => [],
      'video_url' => 'https://staging.example/training-videos/job-costs-1.mp4', 'poster_url' => nil,
      'captions_url' => 'https://staging.example/training-videos/job-costs-1.vtt', 'updated_at' => '2026-10-30T20:00:00Z'
    }
    expect(sync.apply([remote])).to eq(1)
    copy = TrainingVideo.find_by(uid: remote['uid'])
    expect(copy).to have_attributes(title: 'Job costs', share_token: 'tok123456789', is_published: false)
    expect(copy.video_url).to start_with('https://prod.example/training-videos/job-costs-')
    expect(downloads.size).to eq(2)

    expect(sync.apply([remote])).to eq(0)
    sync.apply([remote.merge('title' => 'Job costs and reports', 'is_published' => true, 'updated_at' => '2026-10-30T21:00:00Z')])
    expect(copy.reload).to have_attributes(title: 'Job costs and reports', is_published: true)
    expect(downloads.size).to eq(2)

    sync.apply([])
    expect(copy.reload.is_published).to be(false)
  end
end
