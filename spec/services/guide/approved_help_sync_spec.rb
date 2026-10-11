# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Approve once: copying help from staging', type: :request do
  def snapshot!(entries:, commits: [])
    Knowledge::Snapshot.create!(source: 'frontend', snapshot_at: Time.current, modules_hash: SecureRandom.hex(4),
                                atlas: { 'entries' => entries }, commits: commits)
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
  end

  describe Guide::ApprovedHelpSync do
    it 'publishes a feature\'s help only once production has the feature, and only once' do
      snapshot!(entries: [])
      items = [remote(7, 'atlas_entry', 'report:cash-flow', article_drafts)]
      sync = Guide::ApprovedHelpSync.new(fetcher: ->(_since) { items })

      sync.run
      copy = Knowledge::ChangeQueueItem.find_by("context ->> 'staging_item_id' = '7'")
      expect(copy.status).to eq('pending')
      expect(Knowledge::Article.count).to eq(0)

      snapshot!(entries: [{ 'key' => 'report:cash-flow' }])
      Guide::ApprovedHelpSync.new(fetcher: ->(_since) { items }).run

      expect(copy.reload.status).to eq('auto_applied')
      expect(Knowledge::Article.pluck(:title)).to eq(['Run a Cash Flow'])
      expect(Knowledge::ChangeQueueItem.where("context ->> 'staging_item_id' = '7'").count).to eq(1)
    end

    it 'publishes release notes once production includes their commits' do
      snapshot!(entries: [], commits: [{ 'sha' => 'aaa' }])
      notes = { 'user_facing' => true, 'title' => 'New stuff', 'notes' => '- a thing' }
      Guide::ApprovedHelpSync.new(fetcher: ->(_since) { [remote(8, 'release', 'bbb', notes, shas: ['bbb'])] }).run
      expect(Knowledge::Article.where(article_type: 'release_note').count).to eq(0)

      snapshot!(entries: [], commits: [{ 'sha' => 'bbb' }])
      Guide::ApprovedHelpSync.new(fetcher: ->(_since) { [] }).run
      expect(Knowledge::Article.where(article_type: 'release_note').pluck(:title)).to eq(['New stuff'])
    end

    it 'settles the production change that was waiting for the copy' do
      snap = snapshot!(entries: [{ 'key' => 'report:cash-flow' }])
      waiting = snap.change_queue_items.create!(change_type: 'added', entity_type: 'atlas_entry', entity_key: 'report:cash-flow',
                                                draft_status: 'skipped', context: { 'awaiting_staging' => true })
      Guide::ApprovedHelpSync.new(fetcher: ->(_since) { [remote(9, 'atlas_entry', 'report:cash-flow', article_drafts)] }).run

      expect(waiting.reload.status).to eq('auto_applied')
    end
  end
end
