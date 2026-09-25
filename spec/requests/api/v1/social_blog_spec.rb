# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Api::V1::SocialBlog', type: :request do
  include ActiveJob::TestHelper

  let(:company)  { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  let(:location) { company.locations.create!(name: 'Showroom') }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'U',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin', status: 'active')
  end
  let(:token)   { JsonWebToken.encode(user_id: user.id, company_id: company.id) }
  let(:headers) { { 'Authorization' => "Bearer #{token}", 'Content-Type' => 'application/json' } }
  let!(:website) do
    Website.create!(company_id: company.id, location_id: location.id, name: 'Summit',
                    slug: "s-#{SecureRandom.hex(4)}", status: 'published')
  end
  let(:post_record) { company.social_posts.create!(platform: 'facebook', status: 'draft', caption: 'Hi') }

  describe 'settings' do
    it 'lists the sites and picks the only published one' do
      get '/api/v1/social-blog/settings', headers: headers
      body = JSON.parse(response.body)

      expect(body['settings']).to eq('destination' => 'website_builder', 'website_id' => nil,
                                     'marketing_site_key' => nil, 'default_on' => true,
                                     'link_from_social' => true, 'default_author_name' => nil)
      expect(body['resolved_website_id']).to eq(website.id)
      expect(body['websites'].map { |w| w['id'] }).to eq([website.id])
    end

    it 'saves a chosen site and the default' do
      put '/api/v1/social-blog/settings', params: { website_id: website.id, default_on: false }.to_json, headers: headers

      expect(JSON.parse(response.body)['settings']).to include('website_id' => website.id, 'default_on' => false)
    end

    it 'will not let a non-admin point the company at a marketing site' do
      user.update!(role: 'admin')

      put '/api/v1/social-blog/settings',
          params: { destination: 'marketing_site', marketing_site_key: 'dealertide' }.to_json, headers: headers

      expect(response).to have_http_status(:forbidden)
    end

    it 'aims a saved blog version at the marketing site in the settings' do
      stub_const('ENV', ENV.to_h.merge(
        'MARKETING_BLOG_SITES' => 'dealertide',
        'MARKETING_BLOG_DEALERTIDE_SUPABASE_URL' => 'https://ref.supabase.co',
        'MARKETING_BLOG_DEALERTIDE_SUPABASE_SERVICE_KEY' => 'k',
        'MARKETING_BLOG_DEALERTIDE_COMPANY_UUID' => '1111'
      ))
      put '/api/v1/social-blog/settings',
          params: { destination: 'marketing_site', marketing_site_key: 'dealertide' }.to_json, headers: headers
      expect(JSON.parse(response.body)['marketing_sites'].map { |m| m['key'] }).to eq(['dealertide'])
      expect(response.body).not_to include('"k"')

      put "/api/v1/social-posts/#{post_record.id}/blog", params: { blog: { status: 'pending', title: 'T' } }.to_json,
                                                         headers: headers

      expect(JSON.parse(response.body)['blog']).to include('destination' => 'marketing_site',
                                                           'marketing_site_key' => 'dealertide', 'website_id' => nil)
    end

    it 'rejects another company’s site' do
      other = Company.create!(name: "Other-#{SecureRandom.hex(4)}")
      theirs = Website.create!(company_id: other.id, location_id: other.locations.create!(name: 'L').id,
                               name: 'Theirs', slug: "t-#{SecureRandom.hex(4)}")

      put '/api/v1/social-blog/settings', params: { website_id: theirs.id }.to_json, headers: headers

      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe 'PUT /social-posts/:id/blog' do
    it 'saves the blog version and cleans the body' do
      put "/api/v1/social-posts/#{post_record.id}/blog",
          params: { blog: { status: 'pending', title: 'T', content: '<p>ok</p><script>x</script>' } }.to_json,
          headers: headers

      blog = JSON.parse(response.body)['blog']
      expect(blog).to include('status' => 'pending', 'title' => 'T', 'content' => '<p>ok</p>x')
    end

    it 'will not change one that is already published' do
      post_record.create_blog_cross_post!(company: company, status: 'published', title: 'Live')

      put "/api/v1/social-posts/#{post_record.id}/blog", params: { blog: { title: 'New' } }.to_json, headers: headers

      expect(response).to have_http_status(:unprocessable_entity)
    end

    it 'ignores statuses a person cannot set' do
      put "/api/v1/social-posts/#{post_record.id}/blog",
          params: { blog: { status: 'published', title: 'T' } }.to_json, headers: headers

      expect(JSON.parse(response.body)['blog']['status']).to eq('pending')
    end
  end

  describe 'POST /social-posts/:id/blog/publish' do
    before do
      website.website_pages.create!(title: 'Blog', path: '/blog', blocks: [{ 'type' => 'blogList' }])
      allow_any_instance_of(Website).to receive(:public_url).and_return('https://summit.example.com')
    end

    it 'publishes only the blog version and leaves the social post alone' do
      post_record.create_blog_cross_post!(company: company, status: 'pending', title: 'Only Blog', content: '<p>b</p>')

      post "/api/v1/social-posts/#{post_record.id}/blog/publish", headers: headers

      expect(response).to have_http_status(:ok)
      blog = JSON.parse(response.body)['blog']
      expect(blog['status']).to eq('published')
      expect(blog['public_url']).to include('/blog/post/only-blog')
      expect(post_record.reload.status).to eq('draft')
    end

    it 'links to it when the social post goes out later' do
      post_record.create_blog_cross_post!(company: company, status: 'pending', title: 'Only Blog', content: '<p>b</p>')
      post "/api/v1/social-posts/#{post_record.id}/blog/publish", headers: headers

      link = SocialBlog::SocialLink.prepare(post_record.reload, allow_write: false)
      expect(link).to include('/blog/post/only-blog?')
      expect(BlogPost.count).to eq(1)
    end

    it 'refuses when there is no blog version' do
      post "/api/v1/social-posts/#{post_record.id}/blog/publish", headers: headers
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it 'says why when it cannot publish' do
      website.update!(status: 'draft')
      post_record.create_blog_cross_post!(company: company, status: 'pending', title: 'T', content: '<p>b</p>')

      post "/api/v1/social-posts/#{post_record.id}/blog/publish", headers: headers

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)['error']).to match(/No website/)
    end
  end

  describe 'approval email' do
    let!(:cross_post) do
      post_record.create_blog_cross_post!(company: company, status: 'pending', title: 'Blog T', content: '<p>b</p>')
    end

    it 'shows the blog version and a Facebook only button' do
      mail = SocialPostMailer.approval_needed(post_record, user)
      html = mail.html_part ? mail.html_part.body.to_s : mail.body.to_s

      expect(html).to include('Blog T', 'Facebook Only', 'email_approve_without_blog')
    end

    it 'Facebook only approves the post and skips the blog' do
      t = SocialPostMailer.signed_action_token(post_id: post_record.id, action: 'approve_without_blog')

      post "/api/v1/social-posts/#{post_record.id}/email_approve_without_blog", params: { token: t }

      expect(post_record.reload.status).to eq('approved')
      expect(cross_post.reload.status).to eq('skipped')
    end

    it 'the plain approve link keeps the blog' do
      t = SocialPostMailer.signed_action_token(post_id: post_record.id, action: 'approve')

      post "/api/v1/social-posts/#{post_record.id}/email_approve", params: { token: t }

      expect(post_record.reload.status).to eq('approved')
      expect(cross_post.reload.status).to eq('pending')
    end
  end
end
