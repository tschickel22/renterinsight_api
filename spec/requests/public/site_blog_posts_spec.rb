# frozen_string_literal: true

require 'rails_helper'

# A blog post is a client route with no page row. Without these it shared its
# blog page's title and canonical, was in no sitemap, and a dead post URL
# served the site shell as if it existed.
RSpec.describe 'Public::Sites blog posts', type: :request do
  let(:company)  { Company.create!(name: "Co-#{SecureRandom.hex(3)}") }
  let(:location) { company.locations.create!(name: 'Showroom') }
  let(:author) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'U',
                 password: 'Pass1234!', company_id: company.id, role: 'admin', status: 'active')
  end
  let(:website) do
    Website.create!(company_id: company.id, location_id: location.id, name: 'Sunshine RV',
                    slug: "s-#{SecureRandom.hex(4)}", status: 'published',
                    brand: { 'company_name' => 'Sunshine RV' })
  end
  let!(:home) { website.website_pages.create!(title: 'Home', path: '/', order: 0, blocks: []) }
  let!(:blog) do
    website.website_pages.create!(title: 'Blog', path: '/blog', order: 1, blocks: [{ 'type' => 'blogList' }])
  end
  let!(:domain) do
    company.company_domains.create!(hostname: 'sunshine-rv.test', website_id: website.id, verification_status: 'active')
  end
  let!(:post) do
    website.blog_posts.create!(author: author, title: 'Spring Homes Are Here', slug: 'spring-homes',
                               content: '<p>Three new models.</p>', seo_description: 'Three new models arrived at our lot this spring, with open floor plans.',
                               featured_image_url: 'https://img.example.com/spring.jpg',
                               status: :published, published_at: 1.day.ago)
  end

  before do
    Rails.cache.clear
    allow(Websites::SpaShell).to receive(:fetch) do
      Websites::SpaShell.absolutize('<!doctype html><html><head><title>App</title></head><body></body></html>',
                                    'https://spa.example.com')
    end
  end

  def get_site(path)
    get path, headers: { 'HTTP_HOST' => 'sunshine-rv.test' }
  end

  it 'gives a post its own title, description, image and canonical' do
    get_site('/blog/post/spring-homes')

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('<title>Spring Homes Are Here | Sunshine RV</title>')
    expect(response.body).to include('Three new models arrived at our lot this spring')
    expect(response.body).to include('https://img.example.com/spring.jpg')
    expect(response.body).to include('https://sunshine-rv.test/blog/post/spring-homes')
    expect(response.body).to include('article')
  end

  it 'answers 404 for a post that does not exist' do
    get_site('/blog/post/nope')
    expect(response).to have_http_status(:not_found)
  end

  it 'answers 404 for a draft post' do
    post.update!(status: :draft)
    get_site('/blog/post/spring-homes')
    expect(response).to have_http_status(:not_found)
  end

  it 'lists published posts in the sitemap' do
    website.blog_posts.create!(author: author, title: 'Draft', slug: 'draft-one', content: 'x', status: :draft)

    get_site('/sitemap.xml')

    expect(response.body).to include('<loc>https://sunshine-rv.test/blog/post/spring-homes</loc>')
    expect(response.body).not_to include('draft-one')
  end

  it 'leaves posts out of the sitemap when the site has no blog page' do
    blog.update!(blocks: [])
    get_site('/sitemap.xml')
    expect(response.body).not_to include('spring-homes')
  end
end
