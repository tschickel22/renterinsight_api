# frozen_string_literal: true

require 'rails_helper'

# The Learning Center map: videos, tours and articles placed on the stages from
# first inquiry to money in the bank by the screens they teach.
RSpec.describe 'Learning Center map', type: :request do
  describe Knowledge::LearnMap, '.stage_key' do
    {
      ['/crm/leads/:id'] => 'leads',
      ['/deals/:id'] => 'deal',
      ['/deals/:dealId'] => 'build', # a project's page
      ['/deals/projects'] => 'build',
      ['/deals/:id?tab=home_build'] => 'home',
      ['/accounting/deals-commissions'] => 'close',
      ['/accounting/bills'] => 'money',
      ['/settings'] => 'setup',
      ['/contractor/bids/:id'] => 'build',
      ['/somewhere/new'] => 'more',
      ['/deals/new'] => 'deal',
      [] => 'more',
      ['nav:crm-leads', '/crm'] => 'leads'
    }.each do |routes, stage|
      it "puts #{routes.inspect} on #{stage}" do
        expect(described_class.stage_key(routes)).to eq(stage)
      end
    end

    it 'goes by the first screen listed when two stages match as well' do
      expect(described_class.stage_key(['/settings', '/crm/leads/:id'])).to eq('setup')
    end

    it 'takes the most specific stage when a video shows several screens' do
      expect(described_class.stage_key(['/deals', '/deals/projects'])).to eq('build')
    end
  end

  describe 'GET /api/v1/knowledge/learn_map' do
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
    def stage(key) = body['stages'].find { |s| s['key'] == key }

    let!(:projects_video) do
      TrainingVideo.create!(title: 'Getting around Projects', module_key: 'projects', is_published: true, duration_seconds: 83,
                            video_url: 'https://bucket.example/p.mp4', covers: { 'routes' => ['/deals/projects'] })
    end
    let!(:draft_video) do
      TrainingVideo.create!(title: 'Lead list', module_key: 'crm_sales', video_url: 'https://bucket.example/l.mp4',
                            covers: { 'routes' => ['/crm'] })
    end
    let!(:workflow_video) do
      TrainingVideo.create!(title: 'One home, start to finish', module_key: 'workflows', is_published: true,
                            video_url: 'https://bucket.example/w.mp4', covers: { 'routes' => ['/deals/:id', '/accounting/deals-commissions'] })
    end
    let!(:truebuild_video) do
      TrainingVideo.create!(title: 'Freight rates', module_key: 'truebuild', is_published: true,
                            video_url: 'https://bucket.example/f.mp4', covers: { 'routes' => ['/settings', '/deals/:id'] })
    end
    let!(:loose_video) do
      TrainingVideo.create!(title: 'No screens yet', module_key: 'other', is_published: true, video_url: 'https://bucket.example/x.mp4')
    end
    let!(:article) do
      mod = Knowledge::Module.create!(key: 'leads', name: 'Leads', route: '/crm', is_active: true)
      Knowledge::Article.create!(knowledge_module: mod, title: 'Working your leads', slug: 'working-leads',
                                 content: 'Follow up with prospects.', is_published: true)
    end
    let!(:tour) do
      t = Tour.create!(key: 'bids', name: 'Award a bid', trigger_type: 'manual', position: 1, approved_at: Time.current)
      t.steps.create!(position: 1, selector: '[data-tour="bids"]', route: '/projects/bids', title: 'Bids', content: 'Here')
      t.update_column(:approved_at, Time.current) # editing steps clears approval
      t
    end

    it 'places published videos, approved tours and articles on their stages, in path order' do
      TrainingVideo.enabled = true
      get '/api/v1/knowledge/learn_map', headers: h(dealer)
      expect(response).to have_http_status(:ok)

      expect(body['stages'].map { |s| s['key'] }.first(4)).to eq(%w[start leads customers deal])
      expect(stage('start')['video_ids']).to eq([workflow_video.id])
      expect(stage('truebuild')['video_ids']).to eq([truebuild_video.id])
      expect(stage('setup')).to be_nil.or(include('video_ids' => []))
      expect(stage('build')).to include('video_ids' => [projects_video.id], 'seconds' => 83)
      expect(stage('build')['tours'].map { |t| t['name'] }).to eq(['Award a bid'])
      expect(stage('leads')['articles'].map { |a| a['slug'] }).to eq(['working-leads'])
      expect(stage('leads')['video_ids']).to be_empty # the draft
      expect(stage('more')['video_ids']).to eq([loose_video.id])
    end

    it 'shows dealers no videos while the tab is off, and platform admins the drafts' do
      get '/api/v1/knowledge/learn_map', headers: h(dealer)
      expect(body['stages'].sum { |s| s['video_ids'].size }).to eq(0)

      get '/api/v1/knowledge/learn_map', headers: h(platform)
      expect(stage('leads')['video_ids']).to eq([draft_video.id])
    end

    it 'needs a signed-in person' do
      get '/api/v1/knowledge/learn_map'
      expect(response).to have_http_status(:unauthorized)
    end
  end
end
