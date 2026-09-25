# frozen_string_literal: true

require 'rails_helper'

# Our own companies' social posts can go out as blog posts on our marketing
# sites: a Supabase row plus a Netlify rebuild.
RSpec.describe 'Social post blog version on a marketing site', type: :model do
  let(:env) do
    {
      'MARKETING_BLOG_SITES' => 'dealertide, half',
      'MARKETING_BLOG_DEALERTIDE_NAME' => 'DealerTide website',
      'MARKETING_BLOG_DEALERTIDE_SITE_URL' => 'https://dealertide.example.com/',
      'MARKETING_BLOG_DEALERTIDE_SUPABASE_URL' => 'https://ref.supabase.co',
      'MARKETING_BLOG_DEALERTIDE_SUPABASE_SERVICE_KEY' => 'service-key',
      'MARKETING_BLOG_DEALERTIDE_COMPANY_UUID' => '1111',
      'MARKETING_BLOG_DEALERTIDE_BUILD_HOOK_URL' => 'https://api.netlify.com/build_hooks/abc',
      # Missing its key and company, so it is not offered.
      'MARKETING_BLOG_HALF_SUPABASE_URL' => 'https://half.supabase.co'
    }
  end
  before { stub_const('ENV', ENV.to_h.merge(env)) }

  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  let(:author) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'Tom', last_name: 'S',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin', status: 'active')
  end
  let(:post) do
    company.social_posts.create!(platform: 'facebook', status: 'published', caption: 'Shipped.',
                                 created_by_user_id: author.id, image_urls: ['https://img.example.com/a.jpg'])
  end
  let(:cross_post) do
    post.create_blog_cross_post!(company: company, status: 'pending', destination: 'marketing_site',
                                 marketing_site_key: 'dealertide', title: 'Work Queue Is Live',
                                 slug: 'work-queue-is-live', content: '<p>Body</p>', tags: ['release'])
  end

  describe SocialBlog::MarketingSites do
    it 'offers only sites with everything they need' do
      expect(described_class.all.map(&:key)).to eq(['dealertide'])
      expect(described_class.find('dealertide').post_url('x')).to eq('https://dealertide.example.com/blog/x')
    end
  end

  describe SocialBlog::MarketingSitePublisher do
    let(:calls) { [] }

    def stub_supabase(taken: [], rebuild: nil)
      allow_any_instance_of(described_class).to receive(:request) do |_, method, path, **opts|
        calls << [method, path, opts[:body]]
        if method == :get && path.include?('slug=like')
          taken.map { |s| { 'slug' => s } }
        elsif method == :post
          [{ 'id' => 'uuid-1', 'slug' => opts[:body][:slug], 'published_at' => '2026-09-25T12:00:00Z' }]
        else
          []
        end
      end
      allow_any_instance_of(described_class).to receive(:trigger_rebuild).and_return(rebuild)
    end

    it 'inserts a published row for the site and links to it' do
      stub_supabase

      described_class.call(cross_post)

      _, path, body = calls.detect { |c| c[0] == :post }
      expect(path).to eq('blog_posts')
      expect(body).to include(company_id: '1111', title: 'Work Queue Is Live', status: 'published',
                              author: 'Tom S', featured_image_url: 'https://img.example.com/a.jpg',
                              tags: ['release'])
      expect(body[:published_at]).to be_present
      expect(cross_post.reload).to have_attributes(
        status: 'published', external_id: 'uuid-1',
        public_url: 'https://dealertide.example.com/blog/work-queue-is-live', error: nil
      )
    end

    it 'uses the chosen byline as the author' do
      stub_supabase
      cross_post.update!(author_name: 'Admin')

      described_class.call(cross_post)

      expect(calls.detect { |c| c[0] == :post }[2][:author]).to eq('Admin')
    end

    it 'picks a free slug when that one is taken' do
      stub_supabase(taken: %w[work-queue-is-live work-queue-is-live-2])

      described_class.call(cross_post)

      expect(calls.detect { |c| c[0] == :post }[2][:slug]).to eq('work-queue-is-live-3')
    end

    it 'says so when the rebuild did not start, but keeps the post' do
      stub_supabase(rebuild: 'Netlify answered 500')

      described_class.call(cross_post)

      expect(cross_post.reload.status).to eq('published')
      expect(cross_post.error).to match(/rebuild did not start: Netlify answered 500/)
    end

    it 'does not insert again on a retry' do
      cross_post.update_columns(external_id: 'uuid-1')
      allow_any_instance_of(described_class).to receive(:request)
        .and_return([{ 'id' => 'uuid-1', 'slug' => 'work-queue-is-live', 'published_at' => nil }])
      allow_any_instance_of(described_class).to receive(:trigger_rebuild).and_return(nil)

      expect_any_instance_of(described_class).not_to receive(:insert_row)
      described_class.call(cross_post)
      expect(cross_post.reload.status).to eq('published')
    end

    it 'adopts the row a lost reply left behind instead of inserting a copy' do
      allow_any_instance_of(described_class).to receive(:request) do |_, method, path, **_opts|
        raise 'must not insert' if method == :post

        path.include?('slug=like') ? [{ 'id' => 'orphan', 'slug' => 'work-queue-is-live', 'title' => 'Work Queue Is Live' }] : []
      end
      allow_any_instance_of(described_class).to receive(:trigger_rebuild).and_return(nil)

      described_class.call(cross_post)

      expect(cross_post.reload).to have_attributes(status: 'published', external_id: 'orphan')
    end

    it 'records its id before inserting, so a retry can find the row' do
      ids = []
      allow_any_instance_of(described_class).to receive(:request) do |_, method, path, **opts|
        if method == :post
          ids << [opts[:body][:id], cross_post.reload.external_id]
          raise described_class::Error, 'reply lost'
        end
        []
      end

      expect { described_class.call(cross_post) }.to raise_error(described_class::Error)
      expect(ids.first[0]).to be_present
      expect(ids.first[1]).to eq(ids.first[0])
    end

    it 'turns an unreadable reply into a publish error' do
      site = SocialBlog::MarketingSites.find('dealertide')
      publisher = described_class.new(cross_post)
      res = Net::HTTPOK.new('1.1', '200', 'OK')
      allow(res).to receive(:body).and_return("\x1F\x8B garbage")
      allow_any_instance_of(Net::HTTP).to receive(:request).and_return(res)

      expect(site).to be_present
      expect { publisher.send(:request, :get, 'blog_posts') }.to raise_error(described_class::Error, /could not be read/)
    end

    it 'refuses a site that is not configured' do
      cross_post.update_columns(marketing_site_key: 'gone')
      expect { described_class.call(cross_post) }.to raise_error(described_class::Error, /not configured/)
    end
  end

  describe PublishSocialBlogJob do
    it 'sends a marketing-site version to the marketing-site publisher' do
      cross_post
      expect(SocialBlog::MarketingSitePublisher).to receive(:call).with(cross_post)
      described_class.perform_now(post.id)
    end
  end

  describe 'settings' do
    let(:settings) { SocialBlog::Settings.new(company) }

    it 'aims at the chosen marketing site' do
      settings.update(website_id: nil, default_on: false, destination: 'marketing_site', marketing_site_key: 'dealertide')

      target = settings.resolve_target
      expect(target.destination).to eq('marketing_site')
      expect(target.name).to eq('DealerTide website')
    end

    it 'rejects a marketing site that is not configured' do
      expect {
        settings.update(website_id: nil, default_on: true, destination: 'marketing_site', marketing_site_key: 'half')
      }.to raise_error(ArgumentError)
    end
  end
end
