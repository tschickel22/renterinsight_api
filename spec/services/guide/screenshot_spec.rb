# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Help screenshots (E89)' do
  describe Knowledge::Screenshot do
    let(:shot) { described_class.create!(key: 'deals-board', route: '/deals') }

    it 'finds and strips the shot lines in an article body' do
      body = "Intro\n\n{{shot: deals-board \"The board\"}}\n\nMore\n\n<p>{{shot:quote-button}}</p>"

      expect(described_class.keys_in(body)).to eq(%w[deals-board quote-button])
      expect(described_class.strip(body)).not_to include('shot:')
    end

    it 'replaces the picture and flags the articles when much of the screen changed' do
      shot.record_capture!(size: 'desktop', status: 'ok', url: 'https://one.png', change_score: 1.0)
      expect(shot.reload.needs_review).to be(false) # the first picture is not a change

      shot.record_capture!(size: 'desktop', status: 'ok', url: 'https://two.png', change_score: 0.05)
      expect(shot.reload).to have_attributes(desktop_url: 'https://two.png', desktop_previous_url: 'https://one.png', needs_review: false)

      shot.record_capture!(size: 'desktop', status: 'ok', url: 'https://three.png', change_score: 0.4)
      expect(shot.reload).to have_attributes(desktop_url: 'https://three.png', needs_review: true)
    end
  end

  describe Guide::ScreenshotLoader do
    let!(:article) do
      Knowledge::Article.create!(slug: 'sales-pipeline', title: 'Pipeline', article_type: 'how_to',
                                 content: "## Overview\n\nThe board shows deals.\nOne per card.\n\n## Moving a deal\n\n1. Drag it\n2. Drop it\n\n## Tips\n\nKeep it tidy.")
    end

    let(:data) do
      { 'screenshots' => [{ 'key' => 'deals-board', 'route' => '/deals', 'crop' => 'deals-board', 'title' => 'The board',
                            'articles' => [{ 'slug' => 'sales-pipeline', 'after' => '## Moving a deal', 'caption' => 'Drag a "card"' }] }] }
    end

    it 'makes the recipe and puts the shot after the block under the heading' do
      result = described_class.new(data).load!

      expect(result.placed).to eq(['deals-board -> sales-pipeline'])
      expect(Knowledge::Screenshot.find_by(key: 'deals-board')).to have_attributes(crop_marker: 'deals-board', source: 'file')
      expect(article.reload.content).to include("1. Drag it\n2. Drop it\n\n{{shot: deals-board \"Drag a card\"}}\n\n## Tips")
    end

    it 'adds a shot only once, so moving the line by hand sticks' do
      described_class.new(data).load!
      described_class.new(data).load!

      expect(article.reload.content.scan('{{shot: deals-board').size).to eq(1)
    end

    it 'goes after the first paragraph when the heading is not there' do
      data['screenshots'][0]['articles'][0]['after'] = '## Nope'
      described_class.new(data).load!

      expect(article.reload.content).to start_with("## Overview\n\nThe board shows deals.\nOne per card.\n\n{{shot: deals-board")
    end

    it 'leaves an editor-HTML article alone and says so' do
      article.update!(content: '<h2>Overview</h2><p>Board</p>')

      expect(described_class.new(data).load!.problems.first).to include('is HTML')
      expect(article.reload.content).not_to include('shot:')
    end

    it 'loads the file again only when it changed' do
      path = Rails.root.join('tmp', "shots-#{SecureRandom.hex(3)}.yml")
      File.write(path, data.to_yaml)

      expect(described_class.load_if_changed!(path)).to be_present
      expect(described_class.load_if_changed!(path)).to be_nil
    ensure
      FileUtils.rm_f(path)
    end
  end

  describe 'a drafted article' do
    it 'gets the screenshot the drafter asked for, with a recipe for the nightly run' do
      snap = Knowledge::Snapshot.create!(source: 'frontend', snapshot_at: Time.current, modules_hash: 'x')
      item = snap.change_queue_items.create!(
        change_type: 'added', entity_type: 'atlas_entry', entity_key: 'cash-flow', status: 'pending',
        new_value: { 'key' => 'cash-flow', 'title' => 'Cash Flow', 'route' => '/reports/cash-flow', 'where' => [] },
        drafts: { 'article' => { 'title' => 'Run a Cash Flow', 'excerpt' => 'x', 'content' => "## What it is\n\nMoney in and out.\n\n## Steps\n\n1. Open it" },
                  'screenshot' => { 'key' => 'cash-flow-report-filters', 'route' => '/reports/cash-flow', 'crop_marker' => 'report-filters', 'caption' => 'The filters' } }
      )

      Guide::ReleasePublisher.new(item, nil).publish!

      article = Knowledge::Article.find(item.reload.published_article_id)
      expect(article.content).to include("Money in and out.\n\n{{shot: cash-flow-report-filters \"The filters\"}}")
      expect(Knowledge::Screenshot.find_by(key: 'cash-flow-report-filters')).to have_attributes(crop_marker: 'report-filters', source: 'drafted', desktop_status: 'pending')
    end
  end

  describe Guide::ScreenshotSync do
    def remote(**over)
      { 'key' => 'deals-board', 'route' => '/deals', 'crop_marker' => 'deals-board', 'title' => 'The board',
        'commit_sha' => 'new', 'commit_at' => '2026-11-02T10:00:00Z',
        'desktop' => { 'url' => 'https://staging/d.png', 'status' => 'ok', 'width' => 800, 'height' => 400 },
        'mobile' => { 'url' => 'https://staging/m.png', 'status' => 'broken' } }.merge(over)
    end

    let(:copied) { [] }
    let(:downloader) { ->(url, io) { copied << url; io.write('png') } }

    def sync(known: %w[deals-board], commits: [], built_at: Time.zone.parse('2026-11-01'))
      described_class.new(known_markers: known.to_set, production_commits: commits, production_built_at: built_at, downloader: downloader)
    end

    before { allow_any_instance_of(S3UploadService).to receive(:upload) { |_, _, key:| { url: "https://prod/#{key}" } } }

    it 'copies a picture once production has the build it was taken on' do
      expect(sync(commits: ['new']).apply([remote])).to eq(1)

      shot = Knowledge::Screenshot.find_by(key: 'deals-board')
      expect(shot.desktop_url).to start_with('https://prod/help-screenshots/deals-board-desktop')
      expect(shot).to have_attributes(desktop_status: 'ok', mobile_status: 'pending', source: 'staging')
      expect(copied).to eq(['https://staging/d.png'])

      expect(sync(commits: ['new']).apply([remote])).to eq(0) # unchanged on staging: not copied again
    end

    it 'waits while production is behind or lacks the marker, keeping its picture' do
      expect(sync.apply([remote])).to eq(0)
      expect(sync(commits: ['new'], known: []).apply([remote])).to eq(0)
      expect(sync(built_at: Time.zone.parse('2026-11-03')).apply([remote])).to eq(1)
    end

    it 'updates articles production already has, and never makes new ones' do
      Knowledge::Article.create!(slug: 'pipe', title: 'Pipeline', article_type: 'how_to', content: 'old')

      changed = sync.apply_articles([{ 'slug' => 'pipe', 'title' => 'Pipeline', 'content' => "old\n\n{{shot: deals-board}}" },
                                     { 'slug' => 'staging-only', 'title' => 'New', 'content' => 'x' }])

      expect(changed).to eq(1)
      expect(Knowledge::Article.find_by(slug: 'pipe').content).to include('{{shot: deals-board}}')
      expect(Knowledge::Article.exists?(slug: 'staging-only')).to be(false)
    end
  end
end
