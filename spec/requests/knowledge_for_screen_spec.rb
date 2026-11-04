# frozen_string_literal: true

require 'rails_helper'

# The Learn icon lists what teaches the screen a person is on.
RSpec.describe 'Knowledge help for a screen', type: :request do
  let(:company) { create(:company, use_rbac_system: false) }
  let(:dealer) { make_user('company_admin') }
  let(:platform) { make_user('platform_admin') }

  def make_user(role)
    User.create!(email: "s-#{SecureRandom.hex(4)}@example.com", password: 'Password123!', company: company,
                 first_name: 'S', last_name: 'U', role: role, status: 'active')
  end

  def help_for(user, path, tab = nil)
    get '/api/v1/knowledge/for_screen', params: { path: path, tab: tab }.compact,
                                        headers: { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id)}" }
    expect(response).to have_http_status(:ok)
    JSON.parse(response.body)
  end

  def video(title, routes:, markers: [], published: true)
    TrainingVideo.create!(title: title, slug: title.parameterize, video_url: 'https://example.com/v.mp4',
                          is_published: published, covers: { routes: routes, markers: markers })
  end

  def tour(name, *steps, approved: true)
    t = Tour.create!(key: name.parameterize, name: name)
    steps.each_with_index { |s, i| t.steps.create!({ position: i + 1, title: 'Step', content: 'Do it' }.merge(s)) }
    # Last: changing a step clears an approval.
    t.update_columns(approved_at: Time.current) if approved
    t
  end

  def titles(rows) = rows.map { |r| r['title'] || r['name'] }

  before { TrainingVideo.enabled = true }

  it 'keeps a Settings video to its own tab, and treats no tab as General' do
    video('Users video', routes: ['/settings'], markers: ['settings-tab:users', 'users-add'])
    video('General video', routes: ['/settings'], markers: ['settings-tab:general'])

    expect(titles(help_for(dealer, '/settings', 'users')['videos'])).to eq(['Users video'])
    expect(titles(help_for(dealer, '/settings')['videos'])).to eq(['General video'])
    expect(help_for(dealer, '/settings', 'branding')['videos']).to eq([])
  end

  it 'matches a record page through a :param route, and prefers the exact screen' do
    video('Deal video', routes: ['/deals/:dealId'])
    video('Grid video', routes: ['/deals/projects'])

    expect(titles(help_for(dealer, '/deals/42')['videos'])).to eq(['Deal video'])
    expect(titles(help_for(dealer, '/deals/projects')['videos'])).to eq(['Grid video'])
    expect(help_for(dealer, '/inventory')['videos']).to eq([])
  end

  it 'hides unpublished videos from a dealer, and marks them for a platform admin' do
    video('Draft video', routes: ['/crm'], published: false)

    expect(help_for(dealer, '/crm')['videos']).to eq([])
    row = help_for(platform, '/crm')['videos'].first
    expect(row).to include('title' => 'Draft video', 'draft' => true)
  end

  it 'lists no videos to a dealer while training videos are switched off' do
    video('Live video', routes: ['/crm'])
    TrainingVideo.enabled = false

    expect(help_for(dealer, '/crm')['videos']).to eq([])
  end

  it 'finds tours by the pages their steps visit, approved only for a dealer' do
    tour('Lead tour', { route: '/crm', selector: '[data-tour="add-button"]' })
    tour('Task tour', { selector: '[data-tour="nav:/tasks"]' })
    tour('Unchecked tour', { route: '/crm' }, approved: false)

    row = help_for(dealer, '/crm')['tours']
    expect(titles(row)).to eq(['Lead tour'])
    expect(row.first['steps']).to eq(1)
    expect(titles(help_for(dealer, '/tasks')['tours'])).to eq(['Task tour'])
    expect(titles(help_for(platform, '/crm')['tours'])).to contain_exactly('Lead tour', 'Unchecked tour')
  end

  it 'keeps a Settings tour to the tab it opens' do
    tour('Users tour', { route: '/settings', selector: '[data-tour="settings-tab:users"]' })

    expect(titles(help_for(dealer, '/settings', 'users')['tours'])).to eq(['Users tour'])
    expect(help_for(dealer, '/settings', 'branding')['tours']).to eq([])
  end

  it 'gives dealers no tours while tours are paused' do
    tour('Lead tour', { route: '/crm' })
    PlatformSetting.tours_paused = true

    expect(help_for(dealer, '/crm')['tours']).to eq([])
  ensure
    PlatformSetting.tours_paused = false
  end

  it "lists a module's published articles on its screen, with reading time, never release notes" do
    mod = Knowledge::Module.create!(key: 'leads', name: 'Leads', route: '/api/crm/leads')
    long = (['word'] * 450).join(' ')
    Knowledge::Article.create!(title: 'Managing Leads', slug: 'managing-leads', content: long, is_published: true, knowledge_module: mod)
    Knowledge::Article.create!(title: 'Draft lead help', slug: 'draft-leads', content: 'x', is_published: false, knowledge_module: mod)
    Knowledge::Article.create!(title: 'New in leads', slug: 'new-leads', content: 'x', is_published: true, knowledge_module: mod, article_type: 'release_note')

    rows = help_for(dealer, '/crm/77')['articles']
    expect(rows).to eq([{ 'slug' => 'managing-leads', 'title' => 'Managing Leads', 'minutes' => 3 }])
    expect(help_for(dealer, '/inventory')['articles']).to eq([])
  end

  it 'is empty for a screen nothing covers, and needs a sign-in' do
    expect(help_for(dealer, '/nothing-here')).to eq('videos' => [], 'tours' => [], 'articles' => [])
    get '/api/v1/knowledge/for_screen', params: { path: '/crm' }
    expect(response).to have_http_status(:unauthorized)
  end
end
