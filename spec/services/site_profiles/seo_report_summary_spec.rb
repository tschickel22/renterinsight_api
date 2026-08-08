# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SiteProfiles::SeoReportSummary do
  def report(checks, score: 64, pages: 10, domain: 'mobilehomemasters.com')
    { 'domain' => domain, 'score' => score, 'pages_checked' => pages, 'checks' => checks }
  end

  def check(key, status, weight)
    { 'key' => key, 'label' => key.humanize, 'status' => status, 'weight' => weight }
  end

  # The real shape of the Mobile Home Masters review, so the paragraph is
  # exercised against a prospect we actually measured rather than an invented one.
  let(:prospect) do
    report([
             check('local_business', 'fail', 9),
             check('descriptions', 'fail', 7),
             check('structured_data', 'warn', 10),
             check('image_alt', 'warn', 4),
             check('titles', 'pass', 8)
           ])
  end

  it 'opens with the score and how much was reviewed' do
    expect(described_class.call(prospect)).to start_with(
      'mobilehomemasters.com scores 64 out of 100 across 10 pages reviewed.'
    )
  end

  it 'leads with failures before warnings, heaviest first' do
    summary = described_class.call(prospect).downcase

    expect(summary).to include('nothing tells google this is a dealership at a physical address')
    expect(summary.index('physical address')).to be < summary.index('search engines write the text')
  end

  it 'closes on what it costs them rather than on what is missing' do
    expect(described_class.call(prospect)).to end_with(
      'In practice, a buyer searching for homes in this area may not find this dealership at all.'
    )
  end

  # The client view is the one that leaves the building. A consequence a dealer
  # can feel is persuasive; an instruction is free labour for their incumbent.
  it 'never phrases a finding as an instruction' do
    summary = described_class.call(prospect)

    expect(summary).not_to match(/\badd\b|\bfix\b|\binstall\b|\bimplement\b|should be/i)
  end

  it 'names at most three findings, so it stays a paragraph' do
    many = report(%w[local_business descriptions structured_data image_alt titles headings sitemap]
                    .map { |k| check(k, 'fail', 5) })

    summary = described_class.call(many).downcase
    named = described_class::CONSEQUENCES.values.count { |clause| summary.include?(clause.downcase) }

    expect(named).to eq(described_class::MAX_FINDINGS)
  end

  it 'says so plainly when a site comes back clean' do
    clean = report([check('local_business', 'pass', 9)], score: 100)

    expect(described_class.call(clean)).to include('Nothing came back that would hold the site out')
  end

  it 'is nil when there is nothing to summarise' do
    expect(described_class.call(nil)).to be_nil
    expect(described_class.call({})).to be_nil
    expect(described_class.call(report([], score: nil))).to be_nil
  end

  # The client view drops weights, and this has to keep working on it.
  it 'works on the client view, which carries no weights' do
    client = SiteProfiles::SeoReportView.client(prospect)

    expect(described_class.call(client)).to include('scores 64 out of 100')
  end

  it 'never uses a dash, which is what marks copy as machine written' do
    expect(described_class.call(prospect)).not_to match(/[—–]/)
  end
end
