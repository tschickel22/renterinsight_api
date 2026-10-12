# frozen_string_literal: true

require 'rails_helper'

# Draft help articles are for platform admins; dealers only list published help.
RSpec.describe 'Knowledge article list', type: :request do
  let(:company) { create(:company, use_rbac_system: false) }

  def user(role)
    User.create!(email: "k-#{SecureRandom.hex(4)}@example.com", password: 'Password123!', company: company, first_name: 'K', last_name: 'U', role: role, status: 'active')
  end

  def titles_for(u, published)
    get '/api/v1/knowledge/articles', params: { published: published },
                                      headers: { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: u.id, company_id: company.id)}" }
    JSON.parse(response.body)['articles'].map { |a| a['title'] }
  end

  before do
    Knowledge::Article.create!(title: 'Secret draft', slug: "secret-#{SecureRandom.hex(3)}", is_published: false, content: 'x')
    Knowledge::Article.create!(title: 'Live help', slug: "live-#{SecureRandom.hex(3)}", is_published: true, content: 'y')
  end

  it 'never lists drafts to a dealer, whatever they ask for' do
    dealer = user('company_admin')
    %w[false all].each do |p|
      expect(titles_for(dealer, p)).not_to include('Secret draft')
      expect(titles_for(dealer, p)).to include('Live help')
    end
  end

  it 'lists drafts to a platform admin who asks' do
    expect(titles_for(user('platform_admin'), 'false')).to include('Secret draft')
  end
end
