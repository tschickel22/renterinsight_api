# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Help article screenshots (E89)', type: :request do
  let(:demo) { create(:company, use_rbac_system: false, is_demo: true) }
  let(:dealer) { create(:company, use_rbac_system: false) }

  def make_user(company, role: nil)
    User.create!(email: "shot-#{SecureRandom.hex(4)}@example.com", password: 'Password123!',
                 company: company, first_name: 'Shot', last_name: 'User', role: role)
  end

  def auth(user)
    { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: user.company_id)}" }
  end

  def png_upload
    file = Tempfile.new(['shot', '.png'], binmode: true)
    file.write("\x89PNG\r\n\x1A\n".b + 'rest')
    file.rewind
    Rack::Test::UploadedFile.new(file.path, 'image/png')
  end

  let!(:shot) { Knowledge::Screenshot.create!(key: 'deals-board', route: '/deals', crop_marker: 'deals-board', title: 'The deals board') }
  let(:checker) { make_user(demo) }
  let(:stored) { { url: 'https://assets.example.com/help-screenshots/deals-board-desktop.png', key: 'k', size: 10 } }

  before do
    ENV['GUIDE_CHECK_EMAIL'] = checker.email
    allow(Guide::ScreenshotLoader).to receive(:load_if_changed!)
  end

  after { ENV.delete('GUIDE_CHECK_EMAIL') }

  describe 'the nightly run' do
    it 'lists the recipes and takes a picture from the checker in a demo company' do
      get '/api/v1/help_screenshots/recipes', headers: auth(checker)
      expect(JSON.parse(response.body)['screenshots'].map { |s| s['key'] }).to eq(['deals-board'])

      allow_any_instance_of(S3UploadService).to receive(:upload).and_return(stored)
      post '/api/v1/help_screenshots/deals-board/capture', headers: auth(checker),
                                                          params: { size: 'desktop', status: 'ok', file: png_upload, width: 800, height: 400,
                                                                    commit_sha: 'abc', commit_at: '2026-10-31T10:00:00Z' }

      expect(response).to have_http_status(:ok)
      expect(shot.reload).to have_attributes(desktop_url: stored[:url], desktop_status: 'ok', desktop_width: 800, commit_sha: 'abc')
    end

    it 'refuses the checker account when it is not in a demo company' do
      ENV['GUIDE_CHECK_EMAIL'] = (outsider = make_user(dealer)).email

      post '/api/v1/help_screenshots/deals-board/capture', headers: auth(outsider), params: { size: 'desktop', status: 'ok', file: png_upload }

      expect(response).to have_http_status(:forbidden)
      expect(shot.reload.desktop_url).to be_nil
    end

    it 'refuses anybody but the checker account, even in a demo company' do
      get '/api/v1/help_screenshots/recipes', headers: auth(make_user(demo))

      expect(response).to have_http_status(:forbidden)
    end

    it 'never takes pictures on a server that copies its help from staging' do
      allow(Guide::ApprovedHelpSync).to receive(:configured?).and_return(true)

      get '/api/v1/help_screenshots/recipes', headers: auth(checker)

      expect(response).to have_http_status(:forbidden)
    end

    it 'refuses a file that is not a PNG' do
      file = Tempfile.new(['shot', '.png'])
      file.write('<svg></svg>')
      file.rewind

      post '/api/v1/help_screenshots/deals-board/capture', headers: auth(checker),
                                                          params: { size: 'desktop', status: 'ok', file: Rack::Test::UploadedFile.new(file.path, 'image/png') }

      expect(response).to have_http_status(:unprocessable_entity)
    end

    it 'records a broken shot and keeps the last picture' do
      shot.update!(desktop_url: 'https://old.png', desktop_status: 'ok')

      post '/api/v1/help_screenshots/deals-board/capture', headers: auth(checker),
                                                          params: { size: 'desktop', status: 'broken', error: 'deals-board not found' }

      expect(shot.reload).to have_attributes(desktop_status: 'broken', desktop_error: 'deals-board not found', desktop_url: 'https://old.png')
    end
  end

  describe 'in an article' do
    let!(:article) do
      Knowledge::Article.create!(slug: 'sales-pipeline', title: 'Pipeline', article_type: 'how_to', is_published: true,
                                 content: "## Overview\n\nThe board.\n\n{{shot: deals-board \"The board\"}}\n\n{{shot: missing-one}}")
    end

    it 'gives dealers the pictures that exist and nothing for the others' do
      shot.update!(desktop_url: 'https://d.png', desktop_status: 'ok', mobile_url: 'https://m.png', mobile_status: 'ok')

      get '/api/v1/knowledge/articles/sales-pipeline', headers: auth(make_user(dealer))
      shots = JSON.parse(response.body)['shots']

      expect(shots.keys).to eq(['deals-board'])
      expect(shots['deals-board']).to include('desktop_url' => 'https://d.png', 'mobile_url' => 'https://m.png', 'alt' => 'The deals board')
    end

    it 'falls back to the desktop picture on phones when the mobile one is broken' do
      shot.update!(desktop_url: 'https://d.png', desktop_status: 'ok', mobile_url: 'https://m.png', mobile_status: 'broken')

      get '/api/v1/knowledge/articles/sales-pipeline', headers: auth(make_user(dealer))

      expect(JSON.parse(response.body).dig('shots', 'deals-board')).to include('desktop_url' => 'https://d.png', 'mobile_url' => nil)
    end

    it 'tells a platform admin why a shot is not showing' do
      shot.update!(desktop_status: 'broken', desktop_error: 'deals-board not found')

      get '/api/v1/knowledge/articles/sales-pipeline', headers: auth(make_user(dealer, role: 'platform_admin'))

      expect(JSON.parse(response.body).dig('shots', 'deals-board', 'admin_note')).to include('desktop: deals-board not found')
    end
  end

  describe 'Knowledge admin' do
    let(:admin) { make_user(dealer, role: 'platform_admin') }

    it 'lists shots with the articles that show them, and clears the review flag' do
      Knowledge::Article.create!(slug: 'pipe', title: 'Pipeline', article_type: 'how_to', content: '{{shot: deals-board}}')
      shot.update!(needs_review: true)

      get '/api/admin/knowledge_screenshots', headers: auth(admin)
      row = JSON.parse(response.body)['screenshots'].first
      expect(row['articles'].map { |a| a['slug'] }).to eq(['pipe'])

      post "/api/admin/knowledge_screenshots/#{shot.id}/text_checked", headers: auth(admin)
      expect(shot.reload.needs_review).to be(false)
    end

    it 'is for platform admins only' do
      get '/api/admin/knowledge_screenshots', headers: auth(checker)

      expect(response).to have_http_status(:forbidden)
    end
  end
end
