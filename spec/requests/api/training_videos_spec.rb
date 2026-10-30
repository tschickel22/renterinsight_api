# frozen_string_literal: true

require 'rails_helper'

# E88: training videos in the help center, hidden until switched on, uploaded
# through the server to S3, and shareable by a link that needs no sign-in.
RSpec.describe 'Training videos', type: :request do
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

  let!(:ready) do
    TrainingVideo.create!(title: 'Start a project', module_key: 'projects', is_published: true,
                          video_url: 'https://bucket.example/training-videos/start.mp4')
  end
  let!(:draft) do
    TrainingVideo.create!(title: 'Bids', module_key: 'projects', video_url: 'https://bucket.example/training-videos/bids.mp4')
  end

  it 'hides the tab from dealers until it is switched on, and shows platform admins everything with a file' do
    get '/api/v1/training_videos', headers: h(dealer)
    expect(body).to eq('enabled' => false, 'videos' => [])

    get '/api/v1/training_videos', headers: h(platform)
    expect(body['preview']).to be(true)
    expect(body['videos'].map { |v| v['title'] }).to match_array(['Start a project', 'Bids'])

    TrainingVideo.enabled = true
    get '/api/v1/training_videos', headers: h(dealer)
    expect(body['videos'].map { |v| v['title'] }).to eq(['Start a project'])
    expect(body['videos'].first).not_to have_key('share_token')
  end

  it 'plays a shared video without signing in, until sharing is turned off or the link is replaced' do
    get "/api/public/training_videos/#{draft.share_token}"
    expect(response).to have_http_status(:ok)
    expect(body['video']).to include('title' => 'Bids', 'video_url' => 'https://bucket.example/training-videos/bids.mp4')
    expect(body['video']).not_to have_key('is_published')

    old = draft.share_token
    post "/api/admin/training_videos/#{draft.id}/reset_share_link", headers: h(platform)
    get "/api/public/training_videos/#{old}"
    expect(response).to have_http_status(:not_found)

    draft.reload.update!(share_enabled: false)
    get "/api/public/training_videos/#{draft.share_token}"
    expect(response).to have_http_status(:not_found)
  end

  it 'lets only platform admins manage videos and the switch' do
    put '/api/admin/training_videos/settings', headers: h(dealer), params: { enabled: true }
    expect(response).to have_http_status(:forbidden)

    put '/api/admin/training_videos/settings', headers: h(platform), params: { enabled: true }
    expect(body['enabled']).to be(true)

    post '/api/admin/training_videos', headers: h(platform),
         params: { video: { title: 'Linked installers', module_key: 'projects', chapters: [{ title: 'Link', start: 0 }] } }
    expect(response).to have_http_status(:created), response.body
    expect(body['video']).to include('slug' => 'linked-installers', 'is_published' => false)
    expect(body['video']['share_token']).to be_present
  end

  it 'uploads the MP4 to the assets bucket and refuses other file types' do
    s3 = instance_double(S3UploadService)
    allow(S3UploadService).to receive(:new).and_return(s3)
    allow(s3).to receive(:upload) { |_file, key:| { url: "https://bucket.example/#{key}", key: key, size: 1234 } }
    mp4 = Rack::Test::UploadedFile.new(StringIO.new('fake'), 'video/mp4', original_filename: 'start.mp4')

    post "/api/admin/training_videos/#{draft.id}/upload", headers: h(platform), params: { kind: 'video', file: mp4, duration_seconds: 95 }
    expect(response).to have_http_status(:ok), response.body
    expect(draft.reload.video_url).to match(%r{training-videos/bids-\d+\.mp4\z})
    expect(draft.duration_seconds).to eq(95)

    vtt = Rack::Test::UploadedFile.new(StringIO.new("WEBVTT\n"), 'text/plain', original_filename: 'bids.vtt')
    post "/api/admin/training_videos/#{draft.id}/upload", headers: h(platform), params: { kind: 'captions', file: vtt }
    expect(draft.reload.captions_url).to end_with('.vtt')

    exe = Rack::Test::UploadedFile.new(StringIO.new('x'), 'application/octet-stream', original_filename: 'x.exe')
    post "/api/admin/training_videos/#{draft.id}/upload", headers: h(platform), params: { kind: 'video', file: exe }
    expect(response).to have_http_status(:unprocessable_entity)
  end
end
