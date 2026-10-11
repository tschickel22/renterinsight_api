# frozen_string_literal: true

require 'net/http'

module Guide
  # Production copies the help approved on staging, so it is reviewed once
  # (Tom, 2026-10-11). Runs after each release watch on any server that has
  # GUIDE_SYNC_SOURCE_URL (staging's API) and GUIDE_SYNC_TOKEN set.
  #
  # What is copied goes live only when production has caught up with it:
  #   - help for a page, report or setting: once production's own build has it
  #   - release notes: once production's builds include those commits
  #   - answers to unanswered questions: right away
  # Until then the copy waits in the queue, marked as coming from staging.
  class ApprovedHelpSync
    CURSOR = 'guide_sync_cursor'

    def self.configured?
      ENV['GUIDE_SYNC_SOURCE_URL'].present? && ENV['GUIDE_SYNC_TOKEN'].present?
    end

    def initialize(fetcher: method(:fetch))
      @fetcher = fetcher
    end

    def run
      return 0 unless self.class.configured? || @fetcher != method(:fetch)

      since = Setting.get('Platform', 0, CURSOR, nil)
      items = Array(@fetcher.call(since))
      items.each { |remote| copy(remote) }
      Setting.set('Platform', 0, CURSOR, items.last['reviewed_at']) if items.any?
      publish_ready
    end

    # Copies waiting for production to catch up, published once it has.
    def publish_ready
      published = 0
      waiting.find_each do |item|
        next unless ready?(item)

        Guide::ReleasePublisher.new(item, nil).publish!
        item.update!(status: 'auto_applied')
        # The production change that was waiting for this copy is settled.
        Knowledge::ChangeQueueItem.where(status: 'pending', entity_type: item.entity_type, entity_key: item.entity_key)
                                  .where("context ->> 'awaiting_staging' = 'true'")
                                  .update_all(status: 'auto_applied', reviewed_at: Time.current)
        published += 1
      end
      published
    end

    private

    def fetch(since)
      uri = URI("#{ENV['GUIDE_SYNC_SOURCE_URL'].chomp('/')}/api/public/guide_sync/approved")
      uri.query = URI.encode_www_form(since: since) if since.present?
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https', open_timeout: 10, read_timeout: 30) do |http|
        http.get(uri.request_uri, 'X-Guide-Sync-Token' => ENV['GUIDE_SYNC_TOKEN'], 'Accept' => 'application/json')
      end
      return [] unless response.is_a?(Net::HTTPSuccess)

      JSON.parse(response.body)['items']
    rescue StandardError => e
      Rails.logger.warn("[Guide::ApprovedHelpSync] #{e.class}: #{e.message}")
      []
    end

    def latest_snapshot
      @latest_snapshot ||= Knowledge::Snapshot.where(source: Guide::ReleaseWatcher::SOURCE).order(snapshot_at: :desc).first ||
                           Knowledge::Snapshot.create!(source: Guide::ReleaseWatcher::SOURCE, snapshot_at: Time.current, modules_hash: 'empty')
    end

    def copy(remote)
      return if Knowledge::ChangeQueueItem.where("context ->> 'staging_item_id' = ?", remote['id'].to_s).exists?

      latest_snapshot.change_queue_items.create!(
        change_type: remote['change_type'], entity_type: remote['entity_type'], entity_key: remote['entity_key'],
        new_value: remote['new_value'], drafts: remote['drafts'] || {}, draft_status: 'drafted', status: 'pending',
        context: { 'source' => 'staging', 'staging_item_id' => remote['id'].to_s, 'commit_shas' => Array(remote['commit_shas']) }
      )
    end

    def waiting
      Knowledge::ChangeQueueItem.where(status: 'pending').where("context ->> 'source' = 'staging'")
    end

    def ready?(item)
      case item.entity_type
      when 'gap' then true
      when 'atlas_entry' then Guide::Atlas.entries.any? { |e| e['key'] == item.entity_key }
      when 'release' then (Array(item.context['commit_shas']) & production_commits).any?
      else false
      end
    end

    def production_commits
      @production_commits ||= Knowledge::Snapshot.where(source: Guide::ReleaseWatcher::SOURCE)
                                                 .pluck(:commits).flatten.filter_map { |c| c['sha'] }.uniq
    end
  end
end
