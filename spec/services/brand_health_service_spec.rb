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
  # whole dashboard, so a rejected batch retries with the stable subset.
  it 'retries with the fallback metrics when the batch is rejected' do
    attempts = []
    stub_graph(insights: lambda { |metric|
      attempts << metric
      raise MetaGraphApi::Error, '(#100) The value must be a valid insights metric' if attempts.size == 1

      { 'data' => [{ 'name' => 'page_fans', 'values' => [{ 'value' => 10 }] }] }
    })

    result = described_class.fetch_for_company(company)

    expect(attempts.length).to eq(2)
    expect(attempts.last).to eq(described_class::FALLBACK_METRICS.join(','))
    expect(result).not_to be_nil
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
      expect(Float(result['page_impressions'])).to eq(25)
    end

    it 'sums daily counters across the window' do
      result = extract([
        { 'name' => 'page_post_engagements',
          'values' => [{ 'value' => 3 }, { 'value' => 4 }, { 'value' => 5 }] }
      ])
      expect(result['page_post_engagements']).to eq(12)
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
end
