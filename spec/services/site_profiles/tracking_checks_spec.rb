# frozen_string_literal: true

require 'rails_helper'

# Whether a prospect's site can measure what their ads buy. A dealer paying for
# a website and ads usually assumes the two are connected; often they are not.
RSpec.describe SiteProfiles::TrackingChecks do
  def audit(*heads)
    fetcher = instance_double(SiteProfiles::Fetcher, get: nil)
    pages = heads.each_with_index.to_h do |head, i|
      ["https://dealer.com/#{i}", "<html><head><title>Homes for sale</title>#{head}</head><body><h1>Homes</h1></body></html>"]
    end
    SiteProfiles::SeoAudit.new(source_url: 'https://dealer.com/', pages_html: pages, fetcher: fetcher).call
  end

  def check(report, key) = report['checks'].find { |c| c['key'] == key }

  # Easy Homesource's old site, as served: a Google Ads tag and one conversion
  # label, and nothing else.
  let(:ads_only) do
    <<~HTML
      <script async src="https://www.googletagmanager.com/gtag/js?id=AW-17782600637"></script>
      <script>window.dataLayer=window.dataLayer||[];function gtag(){dataLayer.push(arguments);}
      gtag('js', new Date()); gtag('config', 'AW-17782600637');</script>
      <script>function reportLead(){ gtag('event', 'conversion', {'send_to': 'AW-17782600637/APzlCNyWy9MbEL3ns59C'}); }</script>
    HTML
  end

  it 'finds ads with a conversion but no analytics behind them' do
    report = audit(ads_only)

    expect(check(report, 'ad_tracking')).to include('status' => 'pass', 'headline' => 'Google Ads (AW-17782600637)')
    expect(check(report, 'conversion_tracking')).to include('status' => 'pass')
    expect(check(report, 'conversion_tracking')['headline']).to include('Google Ads conversion')
    analytics = check(report, 'analytics_tracking')
    expect(analytics).to include('status' => 'fail', 'category' => 'tracking')
    expect(analytics['detail']).to include('Ads are tagged (Google Ads) but there is no analytics')
  end

  it 'names every tag it finds, with its id' do
    report = audit(<<~HTML)
      <script async src="https://www.googletagmanager.com/gtag/js?id=G-ABC1234567"></script>
      <script>gtag('config', 'G-ABC1234567');</script>
      <script>fbq('init', '1840905206889397'); fbq('track', 'PageView');</script>
      <script>!function(w,d,t){ttq.load('C4ABCDEFGHIJKLMNOPQR');ttq.page();}(window,document,'ttq');</script>
      <script src="https://cdn.lr-ingest.com/LogRocket.min.js"></script><script>LogRocket.init('abc123/dealer');</script>
    HTML

    expect(report['tracking']['tags'].map { |t| t['vendor'] })
      .to contain_exactly('Google Analytics 4', 'Meta Pixel', 'TikTok Pixel', 'LogRocket')
    expect(report['tracking']['tags'].find { |t| t['vendor'] == 'TikTok Pixel' }['ids']).to eq(['C4ABCDEFGHIJKLMNOPQR'])
    expect(check(report, 'analytics_tracking')['headline']).to eq('Google Analytics 4 (G-ABC1234567)')
  end

  # Tags that only count page views leave the ads optimising for visits, not
  # buyers. That is the gap a dealer's ad agency is paid to close.
  it 'warns when pixels are installed but nothing reports a lead' do
    report = audit("<script>fbq('init', '1840905206889397'); fbq('track', 'PageView');</script>")

    conversion = check(report, 'conversion_tracking')
    expect(conversion).to include('status' => 'warn', 'headline' => 'Tags installed, but no lead event found')
    expect(conversion['detail']).to include('Meta Pixel (1840905206889397) is on the site')
  end

  it 'sees a Meta lead event as a conversion' do
    report = audit("<script>fbq('init', '1840905206889397'); fbq('track', 'Lead');</script>")
    expect(check(report, 'conversion_tracking')['headline']).to eq('Reports leads: Meta lead event')
  end

  it 'fails a site with nothing installed, and says what it cannot see' do
    report = audit('')

    expect(check(report, 'conversion_tracking')).to include('status' => 'fail', 'headline' => 'Nothing reports a lead')
    expect(check(report, 'ad_tracking')['status']).to eq('warn')
    expect(check(report, 'analytics_tracking')['detail']).to include('Tag Manager container')
  end

  # The scores measure whether search engines and assistants can read a site.
  it 'leaves both scores and the SEO gap count alone' do
    with_tags = audit("<script>gtag('config', 'G-ABC1234567');</script><script async src=\"https://www.googletagmanager.com/gtag/js?id=G-ABC1234567\"></script><script>fbq('track', 'Lead')</script>")
    without = audit('')

    expect(with_tags.values_at('score', 'ai_score', 'gap_count')).to eq(without.values_at('score', 'ai_score', 'gap_count'))
    expect(without['tracking_gap_count']).to eq(3)
    expect(with_tags['tracking_gap_count']).to eq(1)
  end
end
