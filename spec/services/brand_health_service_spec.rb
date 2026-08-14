# frozen_string_literal: true

require 'rails_helper'

# Regression: Meta rejects the whole insights call if a single metric name is
# unknown, so the deprecated page_engaged_users / page_views_total silently
# zeroed the entire brand-health dashboard rather than dropping two figures.
RSpec.describe BrandHealthService do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(3)}") }
  let!(:integration) do
    company.facebook_integrations.create!(page_id: 'page-1', page_name: 'DealerTide',
                                          page_access_token: 'PAGE-TOKEN', status: 'active',
                                          is_deleted: false)
  end

  let(:page_data) { { 'id' => 'page-1', 'name' => 'DealerTide', 'fan_count' => 10 } }

  def stub_graph(insights:)
    allow(MetaGraphApi).to receive(:get) do |path, _token, **params|
      if path == '/page-1' then page_data
      elsif path.end_with?('/insights') then insights.call(params[:metric])
      else { 'data' => [] }
      end
    end
  end

  it 'does not request metrics Meta removed in the 2024 cull' do
    expect(described_class::METRICS).not_to include('page_engaged_users', 'page_views_total')
  end

  it 'asks for the current engagement metric' do
    expect(described_class::METRICS).to include('page_post_engagements')
  end

  it 'passes the metric list through on success' do
    seen = nil
    stub_graph(insights: ->(metric) { seen = metric; { 'data' => [] } })

    described_class.fetch_for_company(company)

    expect(seen).to eq(described_class::METRICS.join(','))
  end

  # Metric deprecation is continuous — one unknown name shouldn't cost the
  # whole dashboard, so a rejected batch steps down a rung rather than dropping
  # straight to the floor. Losing reach must not also cost engagement.
  it 'retries with the next rung when the batch is rejected' do
    attempts = []
    stub_graph(insights: lambda { |metric|
      attempts << metric
      raise MetaGraphApi::Error, '(#100) The value must be a valid insights metric' if attempts.size == 1

      { 'data' => [{ 'name' => 'page_fans', 'values' => [{ 'value' => 10 }] }] }
    })

    result = described_class.fetch_for_company(company)

    expect(attempts.length).to eq(2)
    expect(attempts.last).to eq(described_class::METRIC_LADDER[1].join(','))
    expect(attempts.last).to include('page_post_engagements')
    expect(result).not_to be_nil
  end

  it 'drops to the floor only once every richer rung is refused' do
    attempts = []
    stub_graph(insights: lambda { |metric|
      attempts << metric
      raise MetaGraphApi::Error, '(#100) unknown metric' if attempts.size < 3

      { 'data' => [{ 'name' => 'page_fans', 'values' => [{ 'value' => 10 }] }] }
    })

    described_class.fetch_for_company(company)

    expect(attempts.length).to eq(3)
    expect(attempts.last).to eq(described_class::FALLBACK_METRICS.join(','))
  end

  it 'still returns page data when insights fail entirely' do
    stub_graph(insights: ->(_m) { raise MetaGraphApi::Error, 'nope' })

    result = described_class.fetch_for_company(company)

    expect(result).not_to be_nil
    expect(result[:page][:name]).to eq('DealerTide')
  end

  # The dashboard reads these straight into Number(). Returning a nested hash
  # made every tile NaN, which rendered as 0 no matter what Meta sent — reach
  # and engagement read zero on a page that had both.
  describe 'insight shape' do
    def extract(data)
      described_class.send(:extract_insights, { 'data' => data })
    end

    it 'returns plain numbers rather than nested hashes' do
      result = extract([
        { 'name' => 'page_impressions', 'values' => [{ 'value' => 10 }, { 'value' => 15 }] }
      ])

      expect(result['page_impressions']).to be_a(Numeric)
      expect(Float(result['page_impressions'])).to eq(15)
    end

    # We ask for period=days_28, so EACH value Meta returns is already the
    # 28-day total ending on its own end_time, and it sends two or three such
    # windows. Adding them counted most of the same 28 days twice or three
    # times, which is why the dashboard read far higher than Meta Business
    # Suite for the same page. The most recent window is the answer.
    it 'takes the most recent window rather than summing overlapping ones' do
      result = extract([
        { 'name' => 'page_post_engagements',
          'values' => [{ 'value' => 3 }, { 'value' => 4 }, { 'value' => 5 }] }
      ])
      expect(result['page_post_engagements']).to eq(5)
    end

    it 'reports reach from the unique metric, not from impressions' do
      result = extract([
        { 'name' => 'page_impressions_unique', 'values' => [{ 'value' => 40 }] },
        { 'name' => 'page_impressions', 'values' => [{ 'value' => 120 }] }
      ])

      expect(result['page_impressions_unique']).to eq(40)
      expect(result['page_impressions']).to eq(120)
    end

    it 'takes the latest reading for a running total' do
      result = extract([
        { 'name' => 'page_fans', 'values' => [{ 'value' => 100 }, { 'value' => 112 }] }
      ])
      expect(result['page_fans']).to eq(112)
    end

    it 'flattens a breakdown hash into one number' do
      result = extract([
        { 'name' => 'page_impressions',
          'values' => [{ 'value' => { 'organic' => 5, 'paid' => 7 } }] }
      ])
      expect(result['page_impressions']).to eq(12)
    end

    it 'reports zero for a metric Meta omitted, not nil' do
      result = extract([])
      expect(result['page_impressions']).to eq(0)
      expect(result['page_fans']).to eq(0)
    end
  end

  # Posts (30d) read zero because no key by that name was ever returned.
  describe 'posts in the last 30 days' do
    def count(posts)
      described_class.send(:count_last_30_days, posts)
    end

    it 'counts only posts inside the window' do
      expect(count([
        { 'created_time' => 2.days.ago.iso8601 },
        { 'created_time' => 29.days.ago.iso8601 },
        { 'created_time' => 45.days.ago.iso8601 }
      ])).to eq(2)
    end

    it 'ignores a missing or unparseable timestamp' do
      expect(count([
        { 'created_time' => 1.day.ago.iso8601 },
        { 'created_time' => nil },
        { 'created_time' => 'not-a-date' },
        {}
      ])).to eq(1)
    end

    it 'is included in the payload the dashboard reads' do
      stub_graph(insights: ->(_m) { { 'data' => [] } })
      allow(MetaGraphApi).to receive(:get).and_call_original
      allow(MetaGraphApi).to receive(:get).with('/page-1', anything, any_args).and_return(page_data)
      allow(MetaGraphApi).to receive(:get).with('/page-1/insights', anything, any_args)
                                          .and_return({ 'data' => [] })
      allow(MetaGraphApi).to receive(:get).with('/page-1/posts', anything, any_args)
                                          .and_return({ 'data' => [{ 'id' => '1', 'created_time' => 1.day.ago.iso8601 }] })

      result = described_class.fetch_for_company(company)

      expect(result[:insights]['posts_30d']).to eq(1)
    end
  end

  # The Page strip's cards link out to Facebook. The posts query never asked for
  # permalink_url and the payload never carried a link, so the frontend fell
  # back to href="#" and every card just scrolled the dashboard to the top.
  describe 'recent post links' do
    def stub_posts(posts)
      allow(MetaGraphApi).to receive(:get).with('/page-1', anything, any_args).and_return(page_data)
      allow(MetaGraphApi).to receive(:get).with('/page-1/insights', anything, any_args)
                                          .and_return({ 'data' => [] })
      allow(MetaGraphApi).to receive(:get).with('/page-1/posts', anything, any_args)
                                          .and_return({ 'data' => posts })
    end

    it 'asks Meta for the permalink' do
      seen = nil
      allow(MetaGraphApi).to receive(:get) do |path, _token, **params|
        seen = params[:fields] if path == '/page-1/posts'
        path == '/page-1' ? page_data : { 'data' => [] }
      end

      described_class.fetch_for_company(company)

      expect(seen).to include('permalink_url')
    end

    it 'carries the permalink through to the dashboard payload' do
      stub_posts([{ 'id' => 'page-1_900', 'created_time' => 1.day.ago.iso8601,
                    'permalink_url' => 'https://www.facebook.com/dealertide/posts/900' }])

      post = described_class.fetch_for_company(company)[:recent_posts].first

      expect(post[:link]).to eq('https://www.facebook.com/dealertide/posts/900')
    end

    it 'falls back to the post id when Meta returns no permalink' do
      stub_posts([{ 'id' => 'page-1_900', 'created_time' => 1.day.ago.iso8601 }])

      post = described_class.fetch_for_company(company)[:recent_posts].first

      expect(post[:link]).to eq('https://www.facebook.com/page-1_900')
    end

    it 'leaves the link empty rather than inventing one when there is no id' do
      stub_posts([{ 'created_time' => 1.day.ago.iso8601 }])

      post = described_class.fetch_for_company(company)[:recent_posts].first

      expect(post[:link]).to be_nil
    end
  end

  # The comment count on a Page card opens our Comments tab rather than sending
  # the user to Facebook to moderate, but only for a post we published: those
  # are the only ones SyncSocialCommentsJob pulls comments for.
  describe 'linking a Page post back to ours' do
    def stub_posts(posts)
      allow(MetaGraphApi).to receive(:get).with('/page-1', anything, any_args).and_return(page_data)
      allow(MetaGraphApi).to receive(:get).with('/page-1/insights', anything, any_args)
                                          .and_return({ 'data' => [] })
      allow(MetaGraphApi).to receive(:get).with('/page-1/posts', anything, any_args)
                                          .and_return({ 'data' => posts })
    end

    let!(:ours) do
      company.social_posts.create!(platform: 'facebook', status: 'published',
                                   caption: 'Ours', external_post_id: 'page-1_500',
                                   published_at: 1.day.ago)
    end

    it 'names our post so the card can open its comments here' do
      stub_posts([{ 'id' => 'page-1_500', 'created_time' => 1.day.ago.iso8601 }])

      post = described_class.fetch_for_company(company)[:recent_posts].first

      expect(post[:social_post_id]).to eq(ours.id)
    end

    it 'leaves an organic Page post unlinked, since we hold no comments for it' do
      stub_posts([{ 'id' => 'page-1_999', 'created_time' => 1.day.ago.iso8601 }])

      post = described_class.fetch_for_company(company)[:recent_posts].first

      expect(post[:social_post_id]).to be_nil
    end

    it 'never claims another company post as ours' do
      other = Company.create!(name: "Other-#{SecureRandom.hex(3)}")
      other.social_posts.create!(platform: 'facebook', status: 'published',
                                 caption: 'Theirs', external_post_id: 'page-1_777',
                                 published_at: 1.day.ago)
      stub_posts([{ 'id' => 'page-1_777', 'created_time' => 1.day.ago.iso8601 }])

      post = described_class.fetch_for_company(company)[:recent_posts].first

      expect(post[:social_post_id]).to be_nil
    end

    it 'resolves the whole strip in a single query' do
      stub_posts([
        { 'id' => 'page-1_500', 'created_time' => 1.day.ago.iso8601 },
        { 'id' => 'page-1_501', 'created_time' => 2.days.ago.iso8601 },
        { 'id' => 'page-1_502', 'created_time' => 3.days.ago.iso8601 }
      ])

      queries = 0
      counter = ->(_n, _s, _f, _i, payload) do
        queries += 1 if payload[:sql]&.include?('social_posts')
      end

      ActiveSupport::Notifications.subscribed(counter, 'sql.active_record') do
        described_class.fetch_for_company(company)
      end

      expect(queries).to eq(1)
    end
  end
end
