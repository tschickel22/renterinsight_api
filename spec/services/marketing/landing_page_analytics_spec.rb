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

    # A play count means different things depending on how the video is set up,
    # and one number for both invites a wrong reading: on an autoplaying clip it
    # equals visits, so a completion rate measured against it is really how far
    # the average visitor stayed rather than how many chose to watch.
    describe 'an autoplaying video' do
      def autoplay_visit(events)
        v = visit
        events.each { |type| v.record_event!(type, { 'autoplay' => true }, at: 1.hour.ago) }
        v
      end

      it 'says the plays were automatic' do
        autoplay_visit(%w[video_play video_25])

        expect(report[:video][:auto_started]).to be true
      end

      it 'does not claim automatic when the visitor pressed play' do
        visit(events: %w[video_play])

        expect(report[:video][:auto_started]).to be false
      end

      # Reaching for the speaker on a muted clip is a visitor asking to hear it,
      # which on a video with no narration answers whether recording some is
      # worth the effort.
      it 'counts unmutes and rates them against plays' do
        autoplay_visit(%w[video_play video_unmute])
        autoplay_visit(%w[video_play])

        expect(report[:video][:unmuted]).to eq(1)
        expect(report[:video][:unmute_rate]).to eq(50.0)
      end

      it 'reports no unmutes rather than nothing when nobody reached for it' do
        autoplay_visit(%w[video_play video_50])

        expect(report[:video][:unmuted]).to eq(0)
        expect(report[:video][:unmute_rate]).to eq(0.0)
      end
    end
  end

  describe 'where they are' do
    # Country alone cannot answer an ad question when essentially all the
    # traffic is one country. The state is the grain a decision is made at.
    it 'groups by region, ignoring visits recorded before the Worker sent one' do
      visit.update!(country: 'US', region: 'CO')
      visit.update!(country: 'US', region: 'CO')
      visit.update!(country: 'US', region: 'TX')
      visit # no region at all

      expect(report[:sources][:by_region]).to eq('CO' => 2, 'TX' => 1)
    end

    it 'reports an empty map rather than nothing when none was measured' do
      visit

      expect(report[:sources][:by_region]).to eq({})
    end
  end

  describe 'sources' do
    it 'groups by tag, treating an untagged visit with no referrer as direct' do
      visit(utm: 'email')
      visit(utm: 'email')
      visit(utm: nil)

      expect(report[:sources][:by_source]).to eq('email' => 2, 'direct' => 1)
    end

    # This grouped on utm_source alone and called everything else "direct". On
    # the two pages running Meta ads that was wrong for half the traffic: 24 of
    # 47 visits arrived with a facebook.com referrer and 3 carried a tag, so the
    # report said "direct" about paid clicks.
    describe 'a visit nobody tagged' do
      def referred(from)
        v = visit
        v.update!(referrer: from)
        v
      end

      it 'names the site it came from' do
        referred('https://m.facebook.com/')
        referred('https://www.facebook.com/some/path')

        expect(report[:sources][:by_source]['facebook']).to eq(2)
      end

      it 'reports an unrecognised referrer by its host rather than as other' do
        referred('https://news.example.com/article')

        expect(report[:sources][:by_source]['news.example.com']).to eq(1)
      end

      # Crediting the page for its own reloads would inflate whatever source
      # happened to be named alongside them.
      it 'treats a referrer from the page\'s own site as direct' do
        company.company_domains.create!(hostname: 'go.example.com', website_id: site.id,
                                        verification_status: 'active')
        referred('https://go.example.com/fb')

        expect(report[:sources][:by_source]['direct']).to eq(1)
      end

      # A tag says which ad; a referrer only says which site.
      it 'prefers the tag when there is one' do
        v = visit(utm: 'fb-lookalike-may')
        v.update!(referrer: 'https://m.facebook.com/')

        expect(report[:sources][:by_source]['fb-lookalike-may']).to eq(1)
      end
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
