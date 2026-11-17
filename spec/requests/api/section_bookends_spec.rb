# frozen_string_literal: true

require 'rails_helper'

# Section bookends: the few written sentences around a training area's Watch all.
# Found by slug, never offered as articles of their own.
RSpec.describe 'Section bookends', type: :request do
  let(:company) { create(:company) }
  let(:dealer) do
    User.create!(email: "d-#{SecureRandom.hex(3)}@example.com", first_name: 'D', last_name: 'L', password: 'Pass1234!',
                 company_id: company.id, role: 'company_admin', status: 'active')
  end
  def h(user) = { 'Authorization' => "Bearer #{JsonWebToken.generate_access_token(user)}" }
  def body = JSON.parse(response.body)

  let(:mod) { Knowledge::Module.create!(key: 'projects', name: 'Projects', route: '/deals/projects', is_active: true) }
  let!(:recap) do
    Knowledge::Article.create!(knowledge_module: mod, title: 'Projects recap', slug: 'section-recap-projects', is_published: true,
                               content: 'Nothing is billed to the buyer until the phase is approved.')
  end
  let!(:intro) do
    Knowledge::Article.create!(knowledge_module: mod, title: 'Projects intro', slug: 'section-intro-projects', is_published: true,
                               content: 'Projects keeps every install on schedule.')
  end
  let!(:normal) do
    Knowledge::Article.create!(knowledge_module: mod, title: 'How projects work', slug: 'how-projects-work', is_published: true,
                               content: 'A project tracks the install, phase by phase. Approved.')
  end

  it 'takes its type from the slug, so Knowledge admin can write one without a type picker' do
    expect(intro.article_type).to eq('section_intro')
    expect(recap.article_type).to eq('section_recap')
    expect(normal.article_type).not_to start_with('section_')
  end

  it 'is read by its slug for the Watch all' do
    get '/api/v1/knowledge/articles/section-recap-projects', headers: h(dealer)
    expect(response).to have_http_status(:ok)
    expect(body.to_s).to include('Nothing is billed')
  end

  it 'never shows up as an article: search, Ask, the Learn icon, the Learning Center or the article list' do
    slugs = Knowledge::SmartSearchService.new('approved phase projects', user: dealer).search.filter_map { |r| r[:slug] }
    expect(slugs).to include('how-projects-work')
    expect(slugs).not_to include('section-recap-projects', 'section-intro-projects')

    asked = Guide::HelpSearch.call('approved phase projects', limit: 10)
    expect(asked.map(&:slug)).to eq(['how-projects-work'])
    expect(Knowledge::Article.published.standalone).to contain_exactly(normal)
    expect(Knowledge::ScreenHelp.new(path: '/deals/projects').articles).to eq([normal])
    expect(Knowledge::LearnMap.new.stages.flat_map { |s| s[:articles] }).to eq([normal])

    get '/api/v1/knowledge/articles', headers: h(dealer), params: { module: 'projects' }
    expect(body['articles'].map { |a| a['slug'] }).to eq(['how-projects-work'])
    get '/api/v1/knowledge/articles', headers: h(dealer), params: { article_type: 'section_recap' }
    expect(body['articles'].map { |a| a['slug'] }).to eq(['section-recap-projects'])
  end
end
