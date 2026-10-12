# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Approve once: copying help from staging', type: :request do
  def snapshot!(entries:, commits: [], markers: {})
    Knowledge::Snapshot.create!(source: 'frontend', snapshot_at: Time.current, modules_hash: SecureRandom.hex(4),
                                atlas: { 'entries' => entries, 'markers' => markers }, commits: commits)
  end

  def remote(id, type, key, drafts, shas: [])
    { 'id' => id, 'entity_type' => type, 'change_type' => 'added', 'entity_key' => key,
      'new_value' => { 'key' => key, 'title' => 'Cash Flow', 'where' => [] }, 'drafts' => drafts,
      'reviewed_at' => Time.current.iso8601, 'commit_shas' => shas }
  end

  let(:article_drafts) { { 'article' => { 'title' => 'Run a Cash Flow', 'excerpt' => 'x', 'content' => '## Steps' } } }

  describe 'the staging endpoint' do
    before { ENV['GUIDE_SYNC_TOKEN'] = 'secret' }
    after  { ENV.delete('GUIDE_SYNC_TOKEN') }

    it 'serves approved items to the right token only' do
      snap = snapshot!(entries: [])
      snap.change_queue_items.create!(change_type: 'added', entity_type: 'gap', entity_key: 'q', status: 'approved',
                                      reviewed_at: Time.current, drafts: article_drafts)
      snap.change_queue_items.create!(change_type: 'added', entity_type: 'gap', entity_key: 'p', status: 'pending')

      get '/api/public/guide_sync/approved', headers: { 'X-Guide-Sync-Token' => 'wrong' }
      expect(response).to have_http_status(:unauthorized)

      get '/api/public/guide_sync/approved', headers: { 'X-Guide-Sync-Token' => 'secret' }
      expect(JSON.parse(response.body)['items'].map { |i| i['entity_key'] }).to eq(['q'])
    end

    it 'serves help again when its article is edited after approval, with the edit' do
      snap = snapshot!(entries: [])
      article = Knowledge::Article.create!(slug: "cash-#{SecureRandom.hex(2)}", title: 'Run a Cash Flow', content: 'old', article_type: 'how_to', is_published: true)
      article.update_columns(updated_at: 2.days.ago)
      snap.change_queue_items.create!(change_type: 'added', entity_type: 'gap', entity_key: 'q', status: 'approved',
                                      reviewed_at: 2.days.ago, drafts: article_drafts, published_article_id: article.id)
      since = 1.day.ago.iso8601
      get '/api/public/guide_sync/approved', params: { since: since }, headers: { 'X-Guide-Sync-Token' => 'secret' }
      expect(JSON.parse(response.body)['items']).to be_empty

      article.update!(content: '## Fixed steps')
      get '/api/public/guide_sync/approved', params: { since: since }, headers: { 'X-Guide-Sync-Token' => 'secret' }
      item = JSON.parse(response.body)['items'].sole
      expect(item['drafts']['article']['content']).to eq('## Fixed steps')
      expect(Time.zone.parse(item['changed_at'])).to be > 1.minute.ago
    end

    it 'serves approved tours with their steps' do
      mod = Knowledge::Module.create!(key: "users-#{SecureRandom.hex(2)}", name: 'Users')
      tour = Tour.create!(knowledge_module: mod, key: 'manage_users', name: 'Adding users')
      tour.steps.create!(position: 1, selector: '[data-tour="users-add"]', title: 'Add', content: 'Click Add')
      Tour.create!(key: 'unapproved', name: 'Not yet')
      tour.update_columns(approved_at: Time.current)

      get '/api/public/guide_sync/approved', headers: { 'X-Guide-Sync-Token' => 'secret' }
      tours = JSON.parse(response.body)['tours']
      expect(tours.map { |t| [t['module_key'], t['key']] }).to eq([[mod.key, 'manage_users']])
      expect(tours.first['steps'].first).to include('selector' => '[data-tour="users-add"]', 'title' => 'Add')
    end
  end

  describe Guide::ApprovedHelpSync do
    it 'publishes a feature\'s help only once production has the feature, and only once' do
      snapshot!(entries: [])
      items = [remote(7, 'atlas_entry', 'report:cash-flow', article_drafts)]
      sync = Guide::ApprovedHelpSync.new(fetcher: ->(*) { items })

      sync.run
      copy = Knowledge::ChangeQueueItem.find_by("context ->> 'staging_item_id' = '7'")
      expect(copy.status).to eq('pending')
      expect(Knowledge::Article.count).to eq(0)

      snapshot!(entries: [{ 'key' => 'report:cash-flow' }])
      Guide::ApprovedHelpSync.new(fetcher: ->(*) { items }).run

      expect(copy.reload.status).to eq('auto_applied')
      expect(Knowledge::Article.pluck(:title)).to eq(['Run a Cash Flow'])
      expect(Knowledge::ChangeQueueItem.where("context ->> 'staging_item_id' = '7'").count).to eq(1)
    end

    it 'publishes release notes once production includes their commits' do
      snapshot!(entries: [], commits: [{ 'sha' => 'aaa' }])
      notes = { 'user_facing' => true, 'title' => 'New stuff', 'notes' => '- a thing' }
      Guide::ApprovedHelpSync.new(fetcher: ->(*) { [remote(8, 'release', 'bbb', notes, shas: ['bbb'])] }).run
      expect(Knowledge::Article.where(article_type: 'release_note').count).to eq(0)

      snapshot!(entries: [], commits: [{ 'sha' => 'bbb' }])
      Guide::ApprovedHelpSync.new(fetcher: ->(*) { [] }).run
      expect(Knowledge::Article.where(article_type: 'release_note').pluck(:title)).to eq(['New stuff'])
    end

    it 'publishes over its earlier copy when staging approves a correction' do
      snapshot!(entries: [{ 'key' => 'report:cash-flow' }])
      Guide::ApprovedHelpSync.new(fetcher: ->(*) { [remote(7, 'atlas_entry', 'report:cash-flow', article_drafts)] }).run
      fixed = { 'article' => { 'title' => 'Run a Cash Flow', 'excerpt' => 'x', 'content' => '## Fixed steps' } }
      Guide::ApprovedHelpSync.new(fetcher: ->(*) { [remote(7, 'atlas_entry', 'report:cash-flow', fixed)] }).run

      expect(Knowledge::Article.pluck(:content)).to eq(['## Fixed steps'])
      expect(Knowledge::ChangeQueueItem.find_by("context ->> 'staging_item_id' = '7'").status).to eq('auto_applied')
    end

    describe 'tours approved on staging' do
      let(:mod) { Knowledge::Module.create!(key: "users-#{SecureRandom.hex(2)}", name: 'Users') }
      let!(:old_tour) do
        Tour.create!(knowledge_module: mod, key: 'manage_users', name: 'Adding users').tap do |t|
          t.steps.create!(position: 1, selector: '.btn-old', title: 'Old', content: 'Old step')
        end
      end
      let(:remote_tour) do
        { 'key' => 'manage_users', 'module_key' => mod.key, 'name' => 'Add a user', 'is_active' => true,
          'trigger_type' => 'manual', 'approved_at' => 1.hour.ago.iso8601,
          'steps' => [{ 'position' => 1, 'selector' => '[data-tour="nav:/settings"]', 'title' => 'Settings', 'content' => 'Open Settings', 'click_required' => true },
                      { 'position' => 2, 'selector' => '[data-tour="users-add"]', 'title' => 'Add', 'content' => 'Click Add' },
                      { 'position' => 3, 'selector' => '[id="firstName"]', 'title' => 'Name', 'content' => 'Type the name' }] }
      end

      it 'waits for production to have every marker, then goes live already approved' do
        snapshot!(entries: [], markers: { '#firstName' => ['*'] })
        Guide::ApprovedHelpSync.new(fetcher: ->(*) { { 'items' => [], 'tours' => [remote_tour] } }).run
        expect(old_tour.reload.approved_at).to be_nil
        expect(old_tour.steps.pluck(:title)).to eq(['Old'])

        snapshot!(entries: [{ 'key' => 'setting:users', 'where' => [{ 'anchor' => 'nav:/settings' }] }],
                  markers: { 'users-add' => ['/settings'], '#firstName' => ['*'] })
        Guide::ApprovedHelpSync.new(fetcher: ->(*) { { 'items' => [], 'tours' => [] } }).run

        expect(old_tour.reload).to have_attributes(name: 'Add a user', approved_by_id: nil)
        expect(old_tour.approved_at).to be_within(1.second).of(Time.zone.parse(remote_tour['approved_at']))
        expect(old_tour.steps.pluck(:title)).to eq(%w[Settings Add Name])
        expect(Tour.approved.count).to eq(1)
        expect(Setting.get('Platform', 0, Guide::ApprovedHelpSync::PENDING_TOURS, {})).to eq({})
      end

      it 'keeps its cursor so the same approval is not asked for twice' do
        snapshot!(entries: [], markers: {})
        seen = []
        fetcher = ->(_since, tours_since) { seen << tours_since; { 'items' => [], 'tours' => seen.size == 1 ? [remote_tour] : [] } }
        2.times { Guide::ApprovedHelpSync.new(fetcher: fetcher).run }
        expect(seen).to eq([nil, remote_tour['approved_at']])
      end
    end

    it 'settles the production change that was waiting for the copy' do
      snap = snapshot!(entries: [{ 'key' => 'report:cash-flow' }])
      waiting = snap.change_queue_items.create!(change_type: 'added', entity_type: 'atlas_entry', entity_key: 'report:cash-flow',
                                                draft_status: 'skipped', context: { 'awaiting_staging' => true })
      Guide::ApprovedHelpSync.new(fetcher: ->(*) { [remote(9, 'atlas_entry', 'report:cash-flow', article_drafts)] }).run

      expect(waiting.reload.status).to eq('auto_applied')
    end
  end
end
