# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Social post blog version, phase 3', type: :model do
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
  let!(:blog_page) do
    website.website_pages.create!(title: 'Blog', path: '/blog', blocks: [{ 'type' => 'blogList' }])
  end
  let(:post) do
    company.social_posts.create!(platform: 'facebook', status: 'approved', caption: 'New homes are in.',
                                 location_id: location.id, created_by_user_id: author.id,
                                 generation_context: { 'hashtags' => %w[homes] })
  end
  let(:written) do
    { title: 'New Homes', slug: 'new-homes', content: '<p>Long</p>', excerpt: 'e', seo_title: 'New Homes',
      seo_description: 'd', tags: [], ai_generation_version: 'v' }
  end

  before { allow_any_instance_of(Website).to receive(:public_url).and_return('https://summit.example.com') }

  describe SocialBlog::SocialLink do
    let!(:cross_post) do
      post.create_blog_cross_post!(company: company, status: 'pending', title: 'New Homes', content: '<p>Long</p>')
    end

    it 'publishes the blog first and puts its tracked link in the Facebook text' do
      link = described_class.prepare(post, allow_write: false)

      expect(cross_post.reload.status).to eq('published')
      expect(link).to start_with("https://summit.example.com/blog/post/#{BlogPost.last.slug}?")
      expect(link).to include('utm_source=facebook', "utm_content=#{post.id}")

      caption = PublishSocialPostJob.new.send(:build_caption, post.reload)
      expect(caption).to eq("New homes are in.\n\nRead the full post: #{link}\n\n#homes")
    end

    it 'reuses the same link when the post is published again' do
      first = described_class.prepare(post, allow_write: false)
      expect { expect(described_class.prepare(post.reload, allow_write: false)).to eq(first) }
        .not_to change(BlogPost, :count)
    end

    it 'leaves the text alone when the company turned the link off' do
      SocialBlog::Settings.new(company).update(website_id: nil, default_on: true, link_from_social: false)

      expect(described_class.prepare(post, allow_write: false)).to be_nil
      expect(cross_post.reload.status).to eq('pending')
    end

    it 'does not write a version from the Publish button, which is waiting' do
      cross_post.update!(title: nil, content: nil)
      expect(SocialBlog::Generator).not_to receive(:generate)

      expect(described_class.prepare(post, allow_write: false)).to be_nil
    end

    it 'writes one in the background job' do
      cross_post.update!(title: nil, content: nil)
      allow(SocialBlog::Generator).to receive(:generate).and_return(written)

      expect(described_class.prepare(post, allow_write: true)).to include('/blog/post/new-homes')
    end

    it 'skips Instagram, where a link in the caption does nothing' do
      post.update!(platform: 'instagram')
      expect(described_class.prepare(post, allow_write: true)).to be_nil
    end

    it 'never stops the social post when the blog cannot go out' do
      website.update!(status: 'draft')
      expect(described_class.prepare(post, allow_write: false)).to be_nil
    end

    it 'means the after-publish job has nothing left to do' do
      described_class.prepare(post, allow_write: false)
      expect { post.update!(status: 'published') }.not_to have_enqueued_job(PublishSocialBlogJob)
    end
  end

  describe SocialBlog::AutoAttach do
    before { allow(SocialBlog::Generator).to receive(:generate).and_return(written) }

    it 'gives a scheduled post a written blog version by default' do
      cp = described_class.call(post)

      expect(cp).to have_attributes(status: 'pending', destination: 'website_builder', website_id: website.id,
                                    title: 'New Homes')
    end

    it 'follows the schedule when it says no' do
      expect(described_class.call(post, wanted: false)).to be_nil
    end

    it 'follows the company default when the schedule does not say' do
      SocialBlog::Settings.new(company).update(website_id: nil, default_on: false)
      expect(described_class.call(post)).to be_nil
      expect(described_class.call(post, wanted: true)).to be_present
    end

    it 'attaches it unwritten when writing fails, for the publish job to write' do
      allow(SocialBlog::Generator).to receive(:generate).and_raise(SocialBlog::Generator::Error, 'timeout')

      cp = described_class.call(post)
      expect(cp.status).to eq('pending')
      expect(cp).not_to be_written
    end

    it 'skips personal posts' do
      post.update!(post_type: 'rep_personal')
      expect(described_class.call(post)).to be_nil
    end
  end
end
