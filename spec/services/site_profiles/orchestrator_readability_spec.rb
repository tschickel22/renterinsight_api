# frozen_string_literal: true

require 'rails_helper'

# A bot wall answers every request, so a scan can "succeed" having read nothing.
#
# Measured on thehomeplus.com: the live site returns Vercel's security
# checkpoint to any non-browser agent, and the only copy the Wayback Machine
# holds is a 114-byte parked redirect. Both parse as valid HTML and neither is
# the dealership. Before this guard the scan built a Content Profile out of the
# stub, graded it 36/100 "across 1 page", and offered that to the prospect as an
# audit of their own website.
RSpec.describe SiteProfiles::Orchestrator do
  let(:company) { create(:company) }
  let(:profile) do
    SiteContentProfile.create!(
      company: company, source_url: 'https://thehomeplus.com', status: 'pending'
    )
  end

  # The real archived body, byte for byte.
  PARKED_STUB = '<!DOCTYPE html><html><head><script>window.onload=function(){' \
                'window.location.href="/lander"}</script></head></html>'

  # Deliberately a thin page: one heading and three short paragraphs is about
  # the least a real dealer site says about itself, and it still has to scan.
  DEALER_PAGE = <<~HTML
    <html><head><title>Sunshine Homes of Auburn</title></head><body>
      <h1>New and pre-owned manufactured homes in Auburn, Indiana</h1>
      <p>Sunshine Homes has sold and set manufactured homes across northern
         Indiana for twenty five years, handling delivery and foundation work.</p>
      <p>We carry singlewides, doublewides and modular homes from Clayton,
         Skyline and Fleetwood, on the lot and ready to order from the factory.</p>
      <p>Financing is arranged in house, including FHA, VA and conventional
         lending, and most buyers hear back on an application the same week.</p>
    </body></html>
  HTML

  def digest_of(html)
    SiteProfiles::PageDigest.new(
      SiteProfiles::Fetcher::Response.new(
        url: 'https://thehomeplus.com/', status: 200, body: html, content_type: 'text/html'
      )
    ).call
  end

  def fetcher_returning(body, from_archive: false)
    instance_double(SiteProfiles::Fetcher).tap do |f|
      allow(f).to receive(:robots_allows?).and_return(true)
      allow(f).to receive(:get) do |url|
        next nil unless url.to_s.start_with?('https://thehomeplus.com')

        SiteProfiles::Fetcher::Response.new(
          url: url, status: 200, body: body, content_type: 'text/html',
          from_archive: from_archive
        )
      end
    end
  end

  it 'fails the scan when the only page read is a placeholder' do
    orchestrator = described_class.new(profile, fetcher: fetcher_returning(PARKED_STUB, from_archive: true))

    expect { orchestrator.call }.to raise_error(SiteProfiles::Fetcher::FetchError, /nothing to read/i)
  end

  it 'says the archive was the source, and what to do instead' do
    orchestrator = described_class.new(profile, fetcher: fetcher_returning(PARKED_STUB, from_archive: true))

    orchestrator.call
  rescue SiteProfiles::Fetcher::FetchError => e
    expect(e.message).to include('thehomeplus.com')
    expect(e.message).to match(/brochure/i)
  end

  it 'records the failure on the profile rather than leaving it mid-scan' do
    described_class.new(profile, fetcher: fetcher_returning(PARKED_STUB, from_archive: true)).call
  rescue SiteProfiles::Fetcher::FetchError
    expect(profile.reload.status).to eq('failed')
    expect(profile.error_message).to be_present
  end

  # The guard must not reject a site that simply has one good page. Checked
  # against the guard itself rather than a full #call, which would go on to
  # spend a model request on content this example does not care about.
  it 'lets a single thin page of real content through' do
    orchestrator = described_class.new(profile)
    digest = digest_of(DEALER_PAGE)

    expect { orchestrator.send(:ensure_site_was_actually_read!, [digest], nil) }
      .not_to raise_error
  end

  it 'counts a placeholder as unreadable however it was obtained' do
    orchestrator = described_class.new(profile)

    expect(orchestrator.send(:readable_words, digest_of(PARKED_STUB))).to eq(0)
  end
end
