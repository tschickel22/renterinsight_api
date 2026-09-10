# frozen_string_literal: true

require 'rails_helper'

# The text budget used to take the page with it.
#
# paragraphs ran `break` inside filter_map, which makes the whole call return
# nil, so the `.first(MAX_ITEMS)` after it raised. The break only fires once a
# page has spent its 6,000 character budget — so this crashed on exactly the
# pages worth reading. Measured on a live scan of thehomeplus.com: /terms,
# /homes and /locations each rendered successfully and were then discarded,
# leaving 7 pages out of 10 and a warning nobody reads.
RSpec.describe SiteProfiles::PageDigest do
  def digest(html)
    described_class.new(
      SiteProfiles::Fetcher::Response.new(url: 'https://dealer.com/terms', status: 200,
                                          body: html, content_type: 'text/html')
    ).call
  end

  # Comfortably past MAX_TEXT_CHARS.
  let(:long_page) do
    paragraph = 'Manufactured homes are delivered, set and connected by our own crew, ' \
                'and every home is inspected before the keys change hands. ' * 3
    "<html><head><title>Terms</title></head><body>#{"<p>#{paragraph}</p>" * 40}</body></html>"
  end

  it 'reads a page that runs past its text budget instead of raising' do
    expect { digest(long_page) }.not_to raise_error
  end

  it 'keeps the paragraphs it had room for' do
    result = digest(long_page)

    expect(result.paragraphs).to be_an(Array)
    expect(result.paragraphs).not_to be_empty
  end

  it 'still stops at the item cap' do
    expect(digest(long_page).paragraphs.size).to be <= described_class::MAX_ITEMS
  end

  it 'still spends no more than the text budget' do
    total = digest(long_page).paragraphs.sum(&:length)

    # Each kept paragraph is truncated to 500, so the last one can overshoot by
    # its own length; the budget holds to within one paragraph.
    expect(total).to be <= SiteProfiles::PageDigest::MAX_TEXT_CHARS + 500
  end

  it 'leaves a short page exactly as it was' do
    short = '<html><body><p>' + ('A well built home lasts a lifetime. ' * 3) + '</p></body></html>'

    expect(digest(short).paragraphs.size).to eq(1)
  end
end
