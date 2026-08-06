# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marketing::LandingPageAnalytics do
  let(:company) { Company.create!(name: "An-#{SecureRandom.hex(4)}") }
  let(:site) { Marketing::MarketingSiteProvisioner.call(company: company) }
  let(:page) { site.website_pages.create!(title: 'Spring Sale', path: '/spring-sale', page_kind: 'landing') }

  def visit(scroll: 0, converted: false, duration: 0, bot: false, at: 1.hour.ago,
            visitor: SecureRandom.hex(4), utm: nil, device: 'desktop', events: [])
    v = PageVisit.create!(
      company_id: company.id, website_page_id: page.id,
      visitor_token: visitor, session_token: SecureRandom.hex(6),
      max_scroll_depth: scroll, converted: converted, duration_ms: duration,
      is_bot: bot, utm_source: utm, device_type: device,
      first_seen_at: at, last_seen_at: at
    )
    events.each { |type| v.record_event!(type, {}, at: at) }
    v
  end

  subject(:report) { described_class.new(page).call }

  describe 'the funnel' do
    it 'counts visits, unique visitors and conversions' do
      visit(visitor: 'a')
      visit(visitor: 'a') # same person returning
      visit(visitor: 'b', converted: true, events: %w[form_start form_submit])

      funnel = report[:funnel]
      expect(funnel[:visits]).to eq(3)
      expect(funnel[:unique_visitors]).to eq(2)
      expect(funnel[:conversions]).to eq(1)
      expect(funnel[:form_starts]).to eq(1)
    end

    # Many starts and few submits is a form problem, not a traffic problem.
    it 'reports form completion separately from conversion rate' do
      3.times { visit(events: %w[form_start]) }
      visit(converted: true, events: %w[form_start form_submit])

      funnel = report[:funnel]
      expect(funnel[:form_starts]).to eq(4)
      expect(funnel[:form_completion_rate]).to eq(25.0)
      expect(funnel[:conversion_rate]).to eq(25.0)
    end

    it 'counts identified visitors' do
      source = Source.find_or_create_by!(name: 'Web') { |s| s.source_type = 'web' }
      lead = Lead.create!(company: company, source: source, first_name: 'B', last_name: 'One',
                          email: "b-#{SecureRandom.hex(4)}@example.com")
      visit.identify!(lead)
      visit

      expect(report[:funnel][:identified]).to eq(1)
    end

    it 'handles a page with no traffic without dividing by zero' do
      expect(report[:funnel][:conversion_rate]).to eq(0.0)
      expect(report[:funnel][:form_completion_rate]).to eq(0.0)
    end
  end

  # A dealer who sees 400 visits and no enquiries stops trusting the feature.
  describe 'bot exclusion' do
    it 'leaves crawlers out of every number' do
      visit(bot: true, scroll: 100)
      visit(bot: false, scroll: 50)

      expect(report[:funnel][:visits]).to eq(1)
      expect(report[:engagement][:avg_scroll_depth]).to eq(50.0)
    end
  end

  describe 'engagement' do
    it 'reports scroll, bounce and clicks' do
      visit(scroll: 100)
      visit(scroll: 0)
      visit(scroll: 50, events: %w[cta_click outbound_click])

      eng = report[:engagement]
      expect(eng[:reached_bottom]).to eq(1)
      expect(eng[:bounced]).to eq(1)
      expect(eng[:avg_scroll_depth]).to eq(50.0)
      expect(eng[:cta_clicks]).to eq(1)
      expect(eng[:outbound_clicks]).to eq(1)
    end

    # One visitor leaving a tab open for hours would otherwise produce an
    # average that describes nobody.
    it 'uses a median duration so one long tab does not skew it' do
      visit(duration: 5_000)
      visit(duration: 6_000)
      visit(duration: 4_000_000)

      expect(report[:engagement][:median_duration_ms]).to eq(6_000)
    end
  end

  describe 'video' do
    it 'reports quartiles and completion' do
      visit(events: %w[video_play video_25 video_50 video_75 video_complete])
      visit(events: %w[video_play video_25])

      v = report[:video]
      expect(v[:plays]).to eq(2)
      expect(v[:quartile_25]).to eq(2)
      expect(v[:quartile_75]).to eq(1)
      expect(v[:completed]).to eq(1)
      expect(v[:completion_rate]).to eq(50.0)
    end

    it 'reports zero plays without dividing by zero' do
      visit
      expect(report[:video]).to eq(plays: 0)
    end
  end

  describe 'sources' do
    it 'groups by utm source, treating missing as direct' do
      visit(utm: 'email')
      visit(utm: 'email')
      visit(utm: nil)

      expect(report[:sources][:by_utm_source]).to eq('email' => 2, 'direct' => 1)
    end

    it 'groups by device' do
      visit(device: 'mobile')
      visit(device: 'desktop')

      expect(report[:sources][:by_device]).to eq('mobile' => 1, 'desktop' => 1)
    end
  end

  describe 'the window' do
    it 'excludes visits outside it' do
      visit(at: 90.days.ago)
      visit(at: 1.day.ago)

      expect(report[:funnel][:visits]).to eq(1)
    end

    it 'accepts an explicit range' do
      visit(at: 90.days.ago)
      wide = described_class.new(page, from: 120.days.ago, to: Time.current).call

      expect(wide[:funnel][:visits]).to eq(1)
    end
  end

  describe 'timeseries' do
    it 'returns per-day visits and conversions in date order' do
      visit(at: 2.days.ago)
      visit(at: 1.day.ago)
      visit(at: 1.day.ago, converted: true)

      series = report[:timeseries]
      expect(series.size).to eq(2)
      expect(series.map { |r| r[:date] }).to eq(series.map { |r| r[:date] }.sort)
      expect(series.last[:visits]).to eq(2)
      expect(series.last[:conversions]).to eq(1)
    end
  end
end
