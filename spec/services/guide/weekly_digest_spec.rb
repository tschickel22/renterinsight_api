# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Guide::WeeklyDigest, type: :service do
  include ActiveJob::TestHelper

  def entry(key, title, extra = {})
    { 'key' => key, 'kind' => key.split(':').first, 'title' => title, 'route' => "/#{key.split(':').last}",
      'breadcrumb' => ['Reports'], 'requires' => [], 'where' => [{ 'anchor' => "nav:/#{key.split(':').last}", 'title' => title, 'text' => 'Click it.', 'click' => true }] }.merge(extra)
  end

  def snapshot(at, entries, commits)
    Knowledge::Snapshot.create!(source: 'frontend', snapshot_at: at, modules_hash: SecureRandom.hex(4), commit_sha: SecureRandom.hex(4),
                                atlas: { 'entries' => entries, 'markers' => {} }, commits: commits)
  end

  # Stands in for Claude: the week's summary keeps one place, every entry gets an article.
  let(:drafter) do
    Class.new do
      def initialize(item) = @item = item

      def draft!
        drafts = if @item.entity_type == 'release'
                   { 'user_facing' => true, 'title' => 'Cash flow', 'notes' => '- New cash flow report',
                     'dealer_visible_keys' => ['report:cash-flow'], 'skipped' => [{ 'what' => 'Lot map title', 'why' => 'admin only' }] }
                 else
                   { 'article' => { 'title' => 'Cash flow', 'content' => 'x' },
                     'tour' => @item.change_type == 'added' ? { 'name' => 'Where to find Cash Flow', 'steps' => [{ 'selector' => 'x' }] } : nil }.compact
                 end
        @item.update!(drafts: drafts, draft_status: 'drafted')
      end
    end
  end

  let(:monday) { Time.zone.parse('2026-10-12 07:00') }
  let(:pnl) { entry('report:profit-and-loss', 'Profit & Loss') }

  before do
    snapshot(monday - 8.days, [pnl], [{ 'sha' => 'old', 'subject' => 'old' }])
    # Many deploys in the week: a page added and changed, one added and removed, an admin page changed.
    snapshot(monday - 5.days, [pnl, entry('report:cash-flow', 'Cash Flow'), entry('report:temp', 'Temp')], [{ 'sha' => 'c1', 'subject' => 'Cash flow report' }])
    snapshot(monday - 2.days, [pnl.merge('title' => 'Profit and Loss'), entry('report:cash-flow', 'Cash Flow Statement'),
                               entry('page:lot-map', 'Lot Map', 'requires' => [{ 'adminOnly' => true }])],
             [{ 'sha' => 'c2', 'subject' => 'Rename P&L' }, { 'sha' => 'c1', 'subject' => 'Cash flow report' }])
  end

  it 'drafts help once for the net change of the week, only for what dealers would notice, and emails the review' do
    release = nil
    expect { release = described_class.new(now: monday, drafter: drafter).run }
      .to have_enqueued_mail(GuideDigestMailer, :weekly)

    changes = release.context['changes'].map { |c| [c['change'], c['key']] }
    # Added then removed is no change; admin-only places are not dealer help.
    expect(changes).to contain_exactly(%w[added report:cash-flow], %w[modified report:profit-and-loss])
    expect(release.context['commits'].map { |c| c['sha'] }).to contain_exactly('c1', 'c2')

    items = Knowledge::ChangeQueueItem.where(entity_type: 'atlas_entry')
    expect(items.map(&:entity_key)).to eq(['report:cash-flow'])
    expect(items.first.drafts.dig('tour', 'name')).to eq('Where to find Cash Flow')
  end

  it 'runs once a week, and the next week starts where this one ended' do
    described_class.new(now: monday, drafter: drafter).run
    expect(described_class.new(now: monday + 1.hour, drafter: drafter).run).to be_nil

    snapshot(monday + 3.days, [pnl, entry('report:cash-flow', 'Cash Flow Statement')], [{ 'sha' => 'c3', 'subject' => 'Undo rename' }])
    nxt = described_class.new(now: monday + 7.days, drafter: drafter).run
    expect(nxt.context['commits'].map { |c| c['sha'] }).to eq(['c3'])
  end

  it 'points a change at the help an earlier approval made, so approving updates it' do
    earlier = Knowledge::Snapshot.first.change_queue_items.create!(
      change_type: 'added', entity_type: 'atlas_entry', entity_key: 'report:cash-flow', status: 'approved',
      reviewed_at: monday - 30.days, published_article_id: 77, published_tour_id: 88
    )
    expect(earlier).to be_persisted

    described_class.new(now: monday, drafter: drafter).run
    item = Knowledge::ChangeQueueItem.where(entity_type: 'atlas_entry', status: 'pending').last
    expect(item).to have_attributes(published_article_id: 77, published_tour_id: 88)
  end

  it 'never drafts on a server that copies help from staging' do
    allow(Guide::ApprovedHelpSync).to receive(:configured?).and_return(true)
    expect(described_class.new(now: monday, drafter: drafter).run).to be_nil
  end
end
