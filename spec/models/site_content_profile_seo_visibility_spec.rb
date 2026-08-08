# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SiteContentProfile, '#seo_teaser' do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(3)}") }

  def profile(report: { 'gap_count' => 4, 'domain' => 'dealer.com', 'score' => 64 }, **attrs)
    described_class.create!(company: company, source_url: 'https://dealer.com', status: 'ready',
                            source_kind: 'url', seo_report: report, **attrs)
  end

  it 'says nothing while the full report is on show' do
    expect(profile(show_seo_report: true).seo_teaser).to be_nil
  end

  it 'names the gaps when the report is hidden but the teaser is not' do
    teaser = profile(show_seo_report: false, show_seo_teaser: true).seo_teaser

    expect(teaser).to eq(gap_count: 4, domain: 'dealer.com', score: 64)
  end

  # The reason this setting exists. On a site that already scores well, a header
  # reading "we found 2 gaps" is an argument for staying with the incumbent.
  it 'says nothing at all when the teaser is switched off' do
    expect(profile(show_seo_report: false, show_seo_teaser: false).seo_teaser).to be_nil
  end

  it 'defaults to the teaser, so existing demos are unchanged' do
    expect(profile(show_seo_report: false).seo_teaser).to be_present
  end

  it 'has nothing to say about a site with no gaps' do
    clean = profile(report: { 'gap_count' => 0, 'domain' => 'dealer.com', 'score' => 100 },
                    show_seo_report: false, show_seo_teaser: true)

    expect(clean.seo_teaser).to be_nil
  end

  it 'has nothing to say before the audit has run' do
    expect(profile(report: nil, show_seo_report: false).seo_teaser).to be_nil
  end
end
