# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Release watcher', type: :service do
  include ActiveJob::TestHelper

  def entry(key, title, route, extra = {})
    {
      'key' => key, 'kind' => key.split(':').first, 'title' => title, 'route' => route, 'breadcrumb' => ['Reports'],
      'anchors' => [], 'synonyms' => [],
      'where' => [{ 'anchor' => 'nav:/reports', 'title' => 'Reports', 'text' => 'Click Reports.', 'click' => true },
                  { 'route' => '/reports', 'anchor' => "report:#{key.split(':').last}", 'title' => title, 'text' => "Click #{title}.", 'click' => true }]
    }.merge(extra)
  end

  def atlas(commit, entries, commits: [])
    { 'version' => 1, 'commit' => commit, 'entries' => entries, 'markers' => { 'add-button' => ['src/x.tsx'] }, 'commits' => commits }
  end

  def watch(data)
    Guide::ReleaseWatcher.new(fetcher: -> { data }).run
  end

  let(:pnl) { entry('report:profit-and-loss', 'Profit & Loss', '/accounting/reports/profit-and-loss') }
  let(:bs)  { entry('report:balance-sheet', 'Balance Sheet', '/accounting/reports/balance-sheet') }

  describe Guide::ReleaseWatcher do
    it 'records the first build as a baseline without queueing help for everything' do
      snapshot = watch(atlas('a1', [pnl, bs]))
      expect(snapshot.change_queue_items).to be_empty
    end

    it 'does nothing when the build has not changed' do
      watch(atlas('a1', [pnl]))
      expect(watch(atlas('a1', [pnl]))).to be_nil
    end

    it 'queues added, changed and removed places, plus the release, and starts drafting' do
      watch(atlas('a1', [pnl, bs]))
      renamed = pnl.merge('title' => 'Profit and Loss')
      cash = entry('report:cash-flow', 'Cash Flow Statement', '/accounting/reports/cash-flow')
      commits = [{ 'sha' => 'a2', 'subject' => 'Reports: cash flow statement', 'body' => 'Adds it.' },
                 { 'sha' => 'a1', 'subject' => 'older', 'body' => '' }]

      snapshot = nil
      expect { snapshot = watch(atlas('a2', [renamed, cash], commits: commits)) }
        .to have_enqueued_job(Guide::DraftReleaseItemJob).exactly(3).times

      items = snapshot.change_queue_items.map { |i| [i.change_type, i.entity_type, i.entity_key] }
      expect(items).to contain_exactly(
        ['added', 'atlas_entry', 'report:cash-flow'],
        ['removed', 'atlas_entry', 'report:balance-sheet'],
        ['modified', 'atlas_entry', 'report:profit-and-loss'],
        ['modified', 'release', 'a2']
      )
      # Only commits since the previous build.
      expect(snapshot.commits.map { |c| c['sha'] }).to eq(['a2'])
      expect(snapshot.change_queue_items.find_by(change_type: 'removed').draft_status).to eq('skipped')
    end

    it 'ignores an unreadable atlas' do
      expect(watch(nil)).to be_nil
      expect(watch({ 'oops' => true })).to be_nil
    end
  end

  describe Guide::ReleaseDrafter do
    let(:snapshot) do
      Knowledge::Snapshot.create!(source: 'frontend', snapshot_at: Time.current, modules_hash: 'x', commit_sha: 'a2',
                                  atlas: { 'markers' => { 'add-button' => ['src/x.tsx'] } },
                                  commits: [{ 'sha' => 'a2', 'subject' => 'Cash flow', 'body' => '' }])
    end
    let(:item) do
      snapshot.change_queue_items.create!(change_type: 'added', entity_type: 'atlas_entry',
                                          entity_key: 'report:cash-flow', new_value: entry('report:cash-flow', 'Cash Flow Statement', '/accounting/reports/cash-flow'))
    end
    let(:client) do
      Class.new do
        def self.call(**)
          { input: {
            'article_title' => 'Run a Cash Flow Statement',
            'article_excerpt' => 'See where cash came from — and where it went.',
            'article_markdown' => "## Steps\n- **Bills** - what you owe\n1. Open Reports",
            'whats_new' => 'New report – cash flow.',
            'in_page_steps' => [{ 'marker' => 'add-button', 'title' => 'Add', 'text' => 'Real' },
                                { 'marker' => 'made-up-marker', 'title' => 'Nope', 'text' => 'Invented' }]
          }, input_tokens: 100, output_tokens: 50 }
        end
      end
    end

    it 'drafts an article, a tour from the menu walk, and keeps only real markers' do
      Guide::ReleaseDrafter.new(item, client: client).draft!
      drafts = item.reload.drafts

      expect(item.draft_status).to eq('drafted')
      expect(drafts.dig('article', 'title')).to eq('Run a Cash Flow Statement')
      steps = drafts.dig('tour', 'steps')
      expect(steps.map { |s| s['selector'] }).to eq(['[data-tour="nav:/reports"]', '[data-tour="report:cash-flow"]', '[data-tour="add-button"]'])
      expect(steps.first['click_required']).to eq(true)
    end

    it 'takes dashes out of what the AI wrote' do
      Guide::ReleaseDrafter.new(item, client: client).draft!
      text = item.reload.drafts.to_json
      expect(text).not_to match(/—|–/)
      expect(item.drafts.dig('article', 'excerpt')).to eq('See where cash came from, and where it went.')
      expect(item.drafts.dig('article', 'content')).to eq("## Steps\n- **Bills**: what you owe\n1. Open Reports")
    end

    it 'logs the cost as platform usage, not a tenant\'s' do
      expect { Guide::ReleaseDrafter.new(item, client: client).draft! }
        .to change { AiQueryLog.where(feature: 'guide_release_draft', company_id: nil).count }.by(1)
    end
  end

  describe Guide::ReleasePublisher do
    let(:admin) { User.new(id: nil) }
    let(:snapshot) { Knowledge::Snapshot.create!(source: 'frontend', snapshot_at: Time.current, modules_hash: 'x') }
    let(:item) do
      snapshot.change_queue_items.create!(
        change_type: 'added', entity_type: 'atlas_entry', entity_key: 'report:cash-flow', draft_status: 'drafted',
        new_value: entry('report:cash-flow', 'Cash Flow Statement', '/accounting/reports/cash-flow'),
        drafts: {
          'article' => { 'title' => 'Run a Cash Flow Statement', 'excerpt' => 'Where cash went.', 'content' => '## Steps' },
          'whats_new' => 'There is a Cash Flow Statement report.',
          'tour' => { 'name' => 'Where to find Cash Flow Statement', 'steps' => [
            { 'selector' => '[data-tour="nav:/reports"]', 'title' => 'Reports', 'content' => 'Click Reports.', 'click_required' => true },
            { 'route' => '/reports', 'selector' => '[data-tour="report:cash-flow"]', 'title' => 'Cash Flow', 'content' => 'Click it.', 'click_required' => true }
          ] }
        }
      )
    end

    it 'publishes the article, the tour and a What\'s New note' do
      Guide::ReleasePublisher.new(item, nil).publish!
      item.reload

      expect(item.status).to eq('approved')
      expect(Knowledge::Article.find(item.published_article_id)).to have_attributes(title: 'Run a Cash Flow Statement', is_published: true, article_type: 'how_to')
      expect(Knowledge::Article.find(item.published_note_id).article_type).to eq('release_note')
      tour = Tour.find(item.published_tour_id)
      expect(tour.steps.map(&:selector)).to eq(['[data-tour="nav:/reports"]', '[data-tour="report:cash-flow"]'])
      expect(tour.steps.first.placement).to eq('right')
    end

    it 'updates what it made the first time instead of duplicating' do
      Guide::ReleasePublisher.new(item, nil).publish!
      item.update!(drafts: item.drafts.deep_merge('article' => { 'title' => 'Cash Flow, step by step' }))

      expect { Guide::ReleasePublisher.new(item.reload, nil).publish! }.not_to change(Knowledge::Article, :count)
      expect(Knowledge::Article.find(item.published_article_id).title).to eq('Cash Flow, step by step')
    end
  end
end
