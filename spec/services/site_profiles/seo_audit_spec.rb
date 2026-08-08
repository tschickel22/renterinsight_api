# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SiteProfiles::SeoAudit do
  # Stands in for robots.txt and sitemap.xml so no example reaches the network.
  def fetcher(robots: nil, sitemap: nil)
    instance_double(SiteProfiles::Fetcher).tap do |f|
      allow(f).to receive(:get) do |url|
        body = if url.end_with?('/robots.txt') then robots
               elsif url.end_with?('/sitemap.xml') then sitemap
               end
        body && SiteProfiles::Fetcher::Response.new(url: url, status: 200, body: body,
                                                    content_type: 'text/html')
      end
    end
  end

  def audit(pages, robots: "User-agent: *\n", sitemap: nil, from_archive: false)
    described_class.new(source_url: 'https://dealer.com/', pages_html: pages,
                        fetcher: fetcher(robots: robots, sitemap: sitemap),
                        from_archive: from_archive).call
  end

  def check(report, key)
    report['checks'].find { |c| c['key'] == key }
  end

  # Modelled on the markup a Trove-built site actually serves, measured from an
  # archived copy of vhvisionhomes.com. Keeping the competitor's real shape here
  # means the audit is calibrated against the best thing in the market rather
  # than against an imagined bad site.
  let(:competitor_page) do
    <<~HTML
      <html><head>
        <title>Homes | The Shoal Creek (Inventory)</title>
        <meta name="description" content="The Shoal Creek is a double-wide manufactured home for sale from Timber Creek with 3 bedrooms and 2 bathrooms in Fayetteville.">
        <link rel="canonical" href="https://dealer.com/homes/007zeb">
        <meta property="og:title" content="Homes | The Shoal Creek">
        <meta property="og:image" content="https://cdn.example/a.jpg">
        <script type="application/ld+json">
          {"@context":"https://schema.org","@type":"Product","name":"The Shoal Creek",
           "offers":{"@type":"Offer","price":236900,"priceCurrency":"USD"}}
        </script>
      </head><body><h1>The Shoal Creek</h1><img src="a.jpg" alt="front elevation"></body></html>
    HTML
  end

  let(:bare_page) do
    '<html><head></head><body><img src="a.jpg"><img src="b.jpg"></body></html>'
  end

  describe 'a site with nothing' do
    subject(:report) { audit({ 'https://dealer.com/' => bare_page }, robots: nil) }

    it 'reports the gaps a dealer can act on' do
      expect(check(report, 'structured_data')['status']).to eq('fail')
      expect(check(report, 'local_business')['status']).to eq('fail')
      expect(check(report, 'titles')['status']).to eq('fail')
      expect(check(report, 'descriptions')['status']).to eq('fail')
      expect(check(report, 'sitemap')['status']).to eq('fail')
    end

    # Under 40 rather than under 30, because several checks pass by absence: a
    # page with no scripts has nothing render-blocking and a tiny page is not
    # heavy. Those are genuinely not problems, so they earn their weight, and a
    # site missing its title, description, schema and sitemap still lands
    # nowhere near a passing score.
    it 'counts the gaps and scores the site' do
      expect(report['gap_count']).to be > 5
      expect(report['score']).to be < 40
    end

    # A number with no stated basis invites more trust than it has earned, and
    # this one travels to dealers.
    it 'says what the score is and is not' do
      expect(report['score_explainer']).to match(/not a Google ranking/i)
      expect(report['score_explainer']).to match(/does not guarantee traffic/i)
    end

    it 'names the domain the report is about' do
      expect(report['domain']).to eq('dealer.com')
    end

    # Sorted worst first, because the top of the list is what gets read aloud.
    it 'puts failures above warnings' do
      statuses = report['checks'].map { |c| c['status'] }

      expect(statuses.index('fail')).to be < statuses.index('warn')
    end
  end

  describe 'the competitor-shaped site' do
    subject(:report) do
      audit({ 'https://dealer.com/homes/007zeb' => competitor_page },
            sitemap: '<urlset><url><loc>https://dealer.com/</loc></url></urlset>')
    end

    it 'credits the things they do well' do
      %w[structured_data titles descriptions canonical headings social_preview sitemap robots]
        .each { |key| expect(check(report, key)['status']).to eq('pass'), "expected #{key} to pass" }
    end

    # The two gaps found on the real competitor site. These are the openings.
    it 'still finds the local business and breadcrumb gaps' do
      expect(check(report, 'local_business')['status']).to eq('fail')
      expect(check(report, 'breadcrumbs')['status']).to eq('warn')
    end

    it 'scores well without scoring perfectly' do
      expect(report['score']).to be_between(60, 90)
    end
  end

  describe 'individual checks' do
    it 'reads types nested under @graph rather than calling them missing' do
      page = <<~HTML
        <html><head><title>A dealership in town</title>
        <script type="application/ld+json">
        {"@graph":[{"@type":"HomeGoodsStore","name":"Dealer"},{"@type":"BreadcrumbList"}]}
        </script></head><body><h1>Hi</h1></body></html>
      HTML

      report = audit({ 'https://dealer.com/' => page })

      expect(check(report, 'local_business')['status']).to eq('pass')
      expect(check(report, 'breadcrumbs')['status']).to eq('pass')
    end

    it 'survives malformed json-ld instead of failing the scan' do
      page = '<html><head><title>Homes for sale here</title>' \
             '<script type="application/ld+json">{not json</script></head>' \
             '<body><h1>x</h1></body></html>'

      expect { audit({ 'https://dealer.com/' => page }) }.not_to raise_error
    end

    it 'names the pages at fault so the list can be forwarded' do
      report = audit({ 'https://dealer.com/a' => bare_page, 'https://dealer.com/b' => bare_page })

      expect(check(report, 'descriptions')['urls']).to contain_exactly('https://dealer.com/a',
                                                                       'https://dealer.com/b')
    end

    it 'catches two pages sharing one title' do
      page = '<html><head><title>Manufactured homes for sale</title>' \
             '<meta name="description" content="A description long enough to clear the minimum bar set by the audit for usefulness."></head>' \
             '<body><h1>x</h1></body></html>'

      report = audit({ 'https://dealer.com/a' => page, 'https://dealer.com/b' => page })

      expect(check(report, 'titles')['status']).to eq('warn')
      expect(check(report, 'titles')['headline']).to match(/duplicated/i)
    end

    it 'reports missing alt text only once it is widespread' do
      report = audit({ 'https://dealer.com/' => bare_page })

      expect(check(report, 'image_alt')['status']).to eq('warn')
    end

    it 'says nothing about images on a page that has none' do
      report = audit({ 'https://dealer.com/' => '<html><head><title>No pictures here</title></head><body></body></html>' })

      expect(check(report, 'image_alt')).to be_nil
    end
  end

  describe 'a site behind a bot wall' do
    it 'reports the block itself as a finding' do
      report = audit({ 'https://dealer.com/' => competitor_page }, from_archive: true)

      expect(check(report, 'crawlability')['status']).to eq('warn')
      expect(report['from_archive']).to be(true)
    end

    it 'leaves the finding out when the site answered normally' do
      report = audit({ 'https://dealer.com/' => competitor_page })

      expect(check(report, 'crawlability')).to be_nil
    end
  end

  # Same class of defect as flagging a deferred module script for blocking
  # render: a finding that fires on something every competent site does reads as
  # a form letter, and it is the finding a prospect can personally check.
  describe 'pages that are short on purpose' do
    def page_with(words)
      "<html><head><title>A page with a perfectly good title</title></head>" \
        "<body><h1>Heading</h1><p>#{(['word'] * words).join(' ')}</p></body></html>"
    end

    it 'does not call a complete contact page thin' do
      report = audit({ 'https://dealer.com/' => page_with(400),
                       'https://dealer.com/contact' => page_with(60) })

      expect(check(report, 'thin_content')['status']).to eq('pass')
    end

    it 'leaves privacy and terms alone too' do
      report = audit({ 'https://dealer.com/' => page_with(400),
                       'https://dealer.com/privacy-policy' => page_with(40),
                       'https://dealer.com/terms' => page_with(40) })

      expect(check(report, 'thin_content')['status']).to eq('pass')
    end

    # The exemption is for pages whose job is not to rank. A brochure page with
    # nothing on it is still the most common reason a real page never ranks.
    it 'still flags a page that was meant to rank' do
      report = audit({ 'https://dealer.com/' => page_with(400),
                       'https://dealer.com/inventory' => page_with(30) })

      expect(check(report, 'thin_content')['status']).to eq('warn')
      expect(check(report, 'thin_content')['urls']).to eq(['https://dealer.com/inventory'])
    end
  end

  it 'returns an empty report rather than raising when nothing was scanned' do
    report = audit({})

    expect(report['checks']).to be_empty
    expect(report['gap_count']).to eq(0)
    expect(report['score']).to be_nil
  end
end
