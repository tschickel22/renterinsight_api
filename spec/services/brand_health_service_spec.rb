# frozen_string_literal: true

require 'rails_helper'

# Meta rejects a whole multi-metric insights call if a single name is retired,
# which is how the 2025/2026 retirements (impressions, page_fans) zeroed every
# tile, Engagement included. Each metric is now its own request, and a metric
# we could not read comes back as nil so the dashboard can say "Unavailable"
# rather than 0.
RSpec.describe BrandHealthService do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(3)}") }
  let!(:integration) do
    company.facebook_integrations.create!(page_id: 'page-1', page_name: 'DealerTide',
                                          page_access_token: 'PAGE-TOKEN', status: 'active',
                                          is_deleted: false)
  end

  let(:page_data) { { 'id' => 'page-1', 'name' => 'DealerTide', 'fan_count' => 10 } }

  # These describe behavior once Meta approves the permission. The temporary
  # gate itself is covered in meta_app_review_gate_spec.rb.
  before { allow(MetaAppReview).to receive(:awaiting).and_return([]) }

  def stub_graph(insights:)
    allow(MetaGraphApi).to receive(:get) do |path, _token, **params|
      if path == '/page-1' then page_data
      elsif path.end_with?('/insights') then insights.call(params[:metric])
      else { 'data' => [] }
      end
    end
  end

  let(:views_fixture) { JSON.parse(file_fixture('meta/page_views_total_days_28.json').read) }

  # A 28-day response for any metric, shaped like the real one.
  def days_28(metric, *values)
    { 'data' => [{ 'name' => metric, 'period' => 'days_28',
                   'values' => values.map { |v| { 'value' => v, 'end_time' => 1.day.ago.iso8601 } } }] }
  end

  def retired!
    raise MetaGraphApi::Error.new('Meta Graph API error (100): (#100) The value must be a valid insights metric',
                                  code: 100, fbtrace_id: 'AbCdEf123')
  end

  it 'asks only for metrics that survived the 2025/2026 retirements' do
    expect(described_class::METRICS)
      .to contain_exactly('page_views_total', 'page_post_engagements', 'page_follows', 'page_video_views')
    expect(described_class::METRICS).not_to include(
      'page_impressions', 'page_impressions_unique', 'page_impressions_paid', 'page_posts_impressions',
      'page_fans', 'page_fan_adds', 'page_engaged_users', 'page_views_logged_in_total'
    )
  end

  it 'requests each metric on its own, as a 28-day total' do
    calls = []
    allow(MetaGraphApi).to receive(:get) do |path, _token, **params|
      if path.end_with?('/insights')
        calls << [params[:metric], params[:period]]
        { 'data' => [] }
      else
        path == '/page-1' ? page_data : { 'data' => [] }
      end
    end

    described_class.fetch_for_company(company)

    expect(calls).to match_array(described_class::METRICS.map { |m| [m, 'days_28'] })
  end

  it 'reads the real page_views_total response' do
    stub_graph(insights: ->(metric) { metric == 'page_views_total' ? views_fixture : days_28(metric, 1) })

    result = described_class.fetch_for_company(company)

    expect(result[:insights]['page_views_total']).to eq(107)
  end

  # The failure that cost an App Review cycle: one retired name zeroed
  # Engagement, which still works, because it rode in the same request.
  it 'keeps every other tile when one metric is retired' do
    stub_graph(insights: lambda { |metric|
      retired! if metric == 'page_views_total'

      days_28(metric, 40)
    })

    insights = described_class.fetch_for_company(company)[:insights]

    expect(insights['page_views_total']).to be_nil
    expect(insights['page_post_engagements']).to eq(40)
    expect(insights['page_follows']).to eq(40)
    expect(insights['page_video_views']).to eq(40)
  end

  it 'logs the metric, code and fbtrace_id of a rejection' do
    stub_graph(insights: ->(metric) { metric == 'page_follows' ? retired! : days_28(metric, 1) })
    allow(Rails.logger).to receive(:error)

    described_class.fetch_for_company(company)

    expect(Rails.logger).to have_received(:error)
      .with(a_string_including('metric=page_follows', 'code=100', 'fbtrace_id="AbCdEf123"'))
  end

  # Zero and unknown are different. A tile must never read 0 because a call
  # failed, or the dashboard looks like a Page nobody sees.
  it 'reports a failed metric as nil, never 0' do
    stub_graph(insights: ->(_m) { raise MetaGraphApi::Error, 'nope' })

    result = described_class.fetch_for_company(company)

    expect(result[:page][:name]).to eq('DealerTide')
    described_class::METRICS.each { |m| expect(result[:insights][m]).to be_nil }
  end

  it 'reports a metric Meta answered with no values as nil' do
    stub_graph(insights: ->(_m) { { 'data' => [] } })

    insights = described_class.fetch_for_company(company)[:insights]

    described_class::METRICS.each { |m| expect(insights[m]).to be_nil }
  end

  it 'keeps a genuine zero as zero' do
    stub_graph(insights: ->(metric) { days_28(metric, 0) })

    insights = described_class.fetch_for_company(company)[:insights]

    expect(insights['page_post_engagements']).to eq(0)
  end

  # With days_28 each value Meta returns is ALREADY the 28-day total ending on
  # its own end_time, and it sends two or three such windows. Adding them
  # counted the same days two or three times over.
  it 'takes the most recent window rather than summing overlapping ones' do
    stub_graph(insights: ->(metric) { days_28(metric, 3, 4, 5) })

    expect(described_class.fetch_for_company(company)[:insights]['page_post_engagements']).to eq(5)
  end

  it 'flattens a breakdown hash into one number' do
    stub_graph(insights: ->(metric) { days_28(metric, { 'organic' => 5, 'paid' => 7 }) })

    expect(described_class.fetch_for_company(company)[:insights]['page_views_total']).to eq(12)
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
