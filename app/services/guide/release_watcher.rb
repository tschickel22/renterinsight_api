# frozen_string_literal: true

require 'net/http'

module Guide
  # Notices what changed in the product between frontend builds and queues
  # help to be drafted for it (backlog E75, "release watcher").
  #
  # Each build publishes atlas.json (see the frontend's
  # scripts/export-atlas.ts): every page, report, setting and action, plus the
  # commits in the build. This fetches it, and when the commit has moved since
  # the last snapshot, records a snapshot and a change-queue item for each
  # place added, changed or removed, plus one for the release as a whole.
  # Guide::DraftReleaseItemJob then asks Claude for drafts. Nothing is
  # published until a platform admin approves it in Knowledge admin.
  #
  # The very first snapshot is a baseline: it records what exists without
  # queueing anything, or the first run would draft help for every page.
  class ReleaseWatcher
    SOURCE = 'frontend'
    # Fields that make a change worth new help when they differ.
    COMPARED = %w[title route description breadcrumb kind].freeze

    def self.atlas_url
      ENV['GUIDE_ATLAS_URL'].presence || "#{Brand.app_url.to_s.chomp('/')}/atlas.json"
    end

    def initialize(fetcher: method(:fetch_atlas))
      @fetcher = fetcher
    end

    # Returns the new snapshot, or nil when nothing changed.
    def run
      atlas = @fetcher.call
      return nil unless atlas.is_a?(Hash) && atlas['entries'].is_a?(Array)

      previous = Knowledge::Snapshot.where(source: SOURCE).order(snapshot_at: :desc).first
      return nil if previous && atlas['commit'].present? && previous.commit_sha == atlas['commit']

      entries = atlas['entries'].index_by { |e| e['key'] }
      digest = Digest::SHA256.hexdigest(entries.keys.sort.join("\n"))
      # No commit id to compare (a local build): fall back to the map itself.
      return nil if previous && atlas['commit'].blank? && previous.modules_hash == digest

      Knowledge::Snapshot.transaction do
        snapshot = Knowledge::Snapshot.create!(
          source: SOURCE,
          snapshot_at: Time.current,
          commit_sha: atlas['commit'],
          modules_hash: digest,
          features_count: entries.size,
          # The tour drafter reads the field labels and their order on each form.
          atlas: atlas.slice('version', 'generated_at', 'branch', 'context', 'entries', 'markers', 'marker_labels', 'marker_order'),
          commits: new_commits(atlas['commits'], previous)
        )
        queue_changes(snapshot, previous, entries) if previous
        snapshot
      end.tap { |snapshot| enqueue_drafts(snapshot) }
    end

    private

    def fetch_atlas
      uri = URI(self.class.atlas_url)
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https', open_timeout: 10, read_timeout: 20) do |http|
        http.get(uri.request_uri, 'Accept' => 'application/json')
      end
      return nil unless response.is_a?(Net::HTTPSuccess)

      JSON.parse(response.body)
    rescue StandardError => e
      Rails.logger.warn("[Guide::ReleaseWatcher] could not read #{self.class.atlas_url}: #{e.class} #{e.message}")
      nil
    end

    # Only the commits since the last snapshot's build.
    def new_commits(commits, previous)
      list = Array(commits).first(60)
      return list unless previous&.commit_sha

      cut = list.index { |c| c['sha'] == previous.commit_sha }
      cut ? list.first(cut) : list
    end

    def queue_changes(snapshot, previous, entries)
      before = Array(previous.atlas['entries']).index_by { |e| e['key'] }

      (entries.keys - before.keys).each { |key| queue(snapshot, 'added', key, nil, entries[key]) }
      (before.keys - entries.keys).each { |key| queue(snapshot, 'removed', key, before[key], nil) }
      (entries.keys & before.keys).each do |key|
        next if entries[key].slice(*COMPARED) == before[key].slice(*COMPARED)

        queue(snapshot, 'modified', key, before[key], entries[key])
      end

      # The release itself: commits can add a button or change a flow without
      # adding a page, and that still deserves a "What's new" line. Where help
      # is copied from staging, release notes come from there instead.
      return if snapshot.commits.blank? || Guide::ApprovedHelpSync.configured?

      snapshot.change_queue_items.create!(
        change_type: 'modified', entity_type: 'release', entity_key: snapshot.commit_sha.presence || "snapshot-#{snapshot.id}",
        new_value: { 'commit_count' => snapshot.commits.size }, context: { 'commits' => snapshot.commits }
      )
    end

    def queue(snapshot, change_type, key, old_value, new_value)
      # Where help is approved on staging and copied here, nothing is drafted
      # again: the change waits for the staging copy (Guide::ApprovedHelpSync),
      # or a person chooses Redraft for something that skipped staging.
      awaiting = change_type != 'removed' && Guide::ApprovedHelpSync.configured?
      snapshot.change_queue_items.create!(
        change_type: change_type, entity_type: 'atlas_entry', entity_key: key,
        old_value: old_value, new_value: new_value,
        # Removed places need a person to retire their help, not an AI draft.
        draft_status: change_type == 'removed' || awaiting ? 'skipped' : 'pending',
        context: awaiting ? { 'awaiting_staging' => true } : {}
      )
    end

    def enqueue_drafts(snapshot)
      return unless snapshot

      snapshot.change_queue_items.where(draft_status: 'pending').find_each do |item|
        Guide::DraftReleaseItemJob.perform_later(item.id)
      end
      snapshot.update_columns(changes_detected: snapshot.change_queue_items.group(:change_type).count)
    end
  end
end
