# frozen_string_literal: true

require 'rails_helper'

# A week with no new frontend build reports nothing new, not last week again.
RSpec.describe Guide::WeeklyDigest, type: :service do
  include ActiveJob::TestHelper

  def entry(key, title)
    { 'key' => key, 'kind' => 'report', 'title' => title, 'route' => "/#{key}", 'breadcrumb' => ['Reports'], 'requires' => [], 'where' => [] }
  end

  def snapshot(at, entries, sha)
    Knowledge::Snapshot.create!(source: 'frontend', snapshot_at: at, modules_hash: SecureRandom.hex(4), commit_sha: sha,
                                atlas: { 'entries' => entries, 'markers' => {} }, commits: [{ 'sha' => sha, 'subject' => sha }])
  end

  let(:drafter) do
    Class.new do
      def initialize(item) = @item = item
      def draft!
        drafts = @item.entity_type == 'release' ? { 'user_facing' => true, 'notes' => 'x', 'dealer_visible_keys' => ['report:cash-flow'] } : { 'article' => { 'title' => 't', 'content' => 'c' } }
        @item.update!(drafts: drafts, draft_status: 'drafted')
      end
    end
  end

  it 'does not report last week again when nothing was deployed this week' do
    week1 = Time.zone.parse('2026-10-05 13:00')
    week2 = week1 + 7.days
    week3 = week2 + 7.days
    pnl = entry('report:profit-and-loss', 'P&L')
    snapshot(week1 - 1.day, [pnl], 's1')
    described_class.new(now: week1, drafter: drafter).run
    snapshot(week2 - 2.days, [pnl, entry('report:cash-flow', 'Cash Flow')], 's2')
    r2 = described_class.new(now: week2, drafter: drafter).run
    expect(r2.context['changes'].map { |c| c['key'] }).to eq(['report:cash-flow'])

    # No build between week 2 and week 3.
    r3 = described_class.new(now: week3, drafter: drafter).run
    expect(r3.context['changes']).to eq([])
  end
end
