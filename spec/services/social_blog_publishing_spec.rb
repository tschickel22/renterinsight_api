# frozen_string_literal: true

require 'rails_helper'

# The blog version of a social post goes out when the social post does, onto
# the company's website-builder site.
RSpec.describe 'Social post blog version', type: :model do
  include ActiveJob::TestHelper

  let(:company)  { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  let(:location) { company.locations.create!(name: 'Showroom') }
  let(:author) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'U',
                 password: 'Pass1234!', company_id: company.id, role: 'admin', status: 'active')
  end
  let!(:website) do
    Website.create!(company_id: company.id, location_id: location.id, name: 'Summit',
                    slug: "s-#{SecureRandom.hex(4)}", status: 'published')
  end
  let(:post) do
    company.social_posts.create!(platform: 'facebook', status: 'approved', caption: 'New homes are in.',
                                 location_id: location.id, created_by_user_id: author.id,
                                 image_urls: ['https://img.example.com/a.jpg'])
  end

  def cross_post(**attrs)
    post.create_blog_cross_post!({
      company: company, status: 'pending',
      title: 'New Homes Are In', content: '<p>Body</p>', excerpt: 'Short'
    }.merge(attrs))
  end

  describe 'when the social post publishes' do
    it 'queues the blog version' do
      cross_post
      expect { post.update!(status: 'published') }.to have_enqueued_job(PublishSocialBlogJob).with(post.id)
    end

    it 'does nothing when the blog version was skipped' do
      cross_post(status: 'skipped')
      expect { post.update!(status: 'published') }.not_to have_enqueued_job(PublishSocialBlogJob)
    end

    it 'does nothing for a post without one' do
      expect { post.update!(status: 'published') }.not_to have_enqueued_job(PublishSocialBlogJob)
    end
  end

  describe SocialBlog::WebsiteBuilderPublisher do
    before { post.update_columns(status: 'published') }

    it 'creates a published blog post with the first image and the post author' do
      cp = cross_post
      blog = described_class.call(cp)

      expect(blog).to be_published
      expect(blog.published_at).to be_present
      expect(blog.website).to eq(website)
      expect(blog.author).to eq(author)
      expect(blog.featured_image_url).to eq('https://img.example.com/a.jpg')
      expect(cp.reload.status).to eq('published')
      expect(cp.external_id).to eq(blog.id.to_s)
    end

    it 'shows the chosen byline instead of the account name' do
      blog = described_class.call(cross_post(author_name: 'Admin'))
      expect(blog.byline).to eq('Admin')
      expect(blog.author).to eq(author)
    end

    it 'falls back to the account name for the byline' do
      expect(described_class.call(cross_post).byline).to eq('T U')
    end

    it 'does not fail when the slug is already taken on that site' do
      website.blog_posts.create!(author: author, title: 'Taken', slug: 'new-homes-are-in', content: 'x')

      blog = described_class.call(cross_post(slug: 'new-homes-are-in'))

      expect(blog.slug).to eq('new-homes-are-in-2')
    end

    it 'does not make a second copy on a retry' do
      cp = cross_post
      first = described_class.call(cp)
      cp.update_columns(status: 'pending')

      expect { described_class.call(cp.reload) }.not_to change(BlogPost, :count)
      expect(cp.reload.external_id).to eq(first.id.to_s)
    end

    it 'links to the post under the site blog page' do
      website.website_pages.create!(title: 'Blog', path: '/blog', blocks: [{ 'type' => 'blogList' }])
      allow_any_instance_of(Website).to receive(:public_url).and_return('https://summit.example.com')

      cp = cross_post
      blog = described_class.call(cp)

      expect(cp.reload.public_url).to eq("https://summit.example.com/blog/post/#{blog.slug}")
    end

    it 'refuses when there is no site to choose' do
      website.update!(status: 'draft')
      expect { described_class.call(cross_post) }.to raise_error(described_class::Error, /No website/)
    end
  end

  describe PublishSocialBlogJob do
    before { post.update_columns(status: 'published') }

    it 'writes the blog version first when nobody did' do
      cp = cross_post(title: nil, content: nil)
      allow(SocialBlog::Generator).to receive(:generate).and_return(
        title: 'Written', slug: 'written', content: '<p>Long</p>', excerpt: 'e',
        seo_title: 'Written', seo_description: 'd', tags: ['homes'], ai_generation_version: 'v'
      )

      described_class.perform_now(post.id)

      expect(cp.reload.status).to eq('published')
      expect(BlogPost.find(cp.external_id).title).to eq('Written')
    end

    it 'records the reason when it cannot publish' do
      website.update!(status: 'draft')
      cp = cross_post

      described_class.perform_now(post.id)

      expect(cp.reload.status).to eq('failed')
      expect(cp.error).to match(/No website/)
    end
  end

  describe SocialBlog::Generator do
    it 'strips tags that are not allowed from the body' do
      html = '<h1>Big</h1><p onclick="x()">Hi <script>alert(1)</script><a href="/x" style="c">l</a></p>'
      expect(described_class.sanitize_html(html)).to eq('Big<p>Hi <a href="/x">l</a></p>')
    end

    it 'keeps an existing category spelling' do
      reply = { 'content' => [{ 'text' => { title: 'T', content_html: '<p>B</p>', category: 'buying guides' }.to_json }] }
      allow(Rails.application.credentials).to receive(:dig).and_call_original
      allow(Rails.application.credentials).to receive(:dig).with(:anthropic, :api_key).and_return('key')
      allow_any_instance_of(described_class).to receive(:call_claude).and_return(reply)

      result = described_class.generate(company: company, caption: 'x', categories: ['Buying Guides', 'News'])
      expect(result[:category]).to eq('Buying Guides')
    end

    it 'turns the model reply into blog fields' do
      reply = { 'content' => [{ 'text' => {
        title: 'Spring Homes', slug: '', excerpt: 'Short', content_html: '<h2>A</h2><p>B</p>',
        seo_title: '', seo_description: 'Desc', tags: ['homes', '']
      }.to_json }] }
      allow(Rails.application.credentials).to receive(:dig).and_call_original
      allow(Rails.application.credentials).to receive(:dig).with(:anthropic, :api_key).and_return('key')
      allow_any_instance_of(described_class).to receive(:call_claude).and_return(reply)

      result = described_class.generate(company: company, caption: 'Spring homes are here')

      expect(result).to include(title: 'Spring Homes', slug: 'spring-homes', seo_title: 'Spring Homes',
                                content: '<h2>A</h2><p>B</p>', tags: ['homes'])
    end

    it 'refuses before there is a social post to work from' do
      expect { described_class.generate(company: company, caption: ' ') }.to raise_error(described_class::Error)
    end
  end
end
