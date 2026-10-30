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
  #   - tours approved on staging: once production's build has every marker
  #     their steps point at, and then already approved
  # Until then the copy waits in the queue, marked as coming from staging.
  # Help approved again or edited on staging after it was copied is copied
  # again, so a correction made on staging reaches production.
  class ApprovedHelpSync
    CURSOR = 'guide_sync_cursor'
    TOUR_CURSOR = 'guide_sync_tour_cursor'
    # Tours from staging waiting for production's build, by module and key.
    PENDING_TOURS = 'guide_sync_pending_tours'
    STEP_FIELDS = %w[position route selector title content placement highlight_type click_required input_required].freeze

    def self.configured?
      ENV['GUIDE_SYNC_SOURCE_URL'].present? && ENV['GUIDE_SYNC_TOKEN'].present?
    end

    def initialize(fetcher: method(:fetch))
      @fetcher = fetcher
    end

    def run
      return 0 unless self.class.configured? || @fetcher != method(:fetch)

      since = Setting.get('Platform', 0, CURSOR, nil)
      tours_since = Setting.get('Platform', 0, TOUR_CURSOR, nil)
      payload = @fetcher.call(since, tours_since)
      payload = { 'items' => payload } if payload.is_a?(Array)
      items = Array(payload['items'])
      items.each { |remote| copy(remote) }
      Setting.set('Platform', 0, CURSOR, items.last['changed_at'] || items.last['reviewed_at']) if items.any?
      tours = Array(payload['tours'])
      queue_tours(tours)
      Setting.set('Platform', 0, TOUR_CURSOR, tours.last['approved_at']) if tours.any?
      published = publish_ready
      apply_ready_tours
      # Training videos: only when staging sent its list (an older staging, or
      # a failed fetch, sends none and must not hide anything here).
      Guide::TrainingVideoSync.new.apply(payload['videos']) if payload.key?('videos')
      published
    end

    # Tours waiting for production's build, put live (and approved) once it
    # has every marker their steps point at.
    def apply_ready_tours
      pending = pending_tours
      return 0 if pending.empty?

      known = known_markers
      applied = pending.select { |_, remote| tour_ready?(remote, known) }
      applied.each_value { |remote| apply_tour(remote) }
      Setting.set('Platform', 0, PENDING_TOURS, pending.except(*applied.keys))
      applied.size
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

    def fetch(since, tours_since)
      uri = URI("#{ENV['GUIDE_SYNC_SOURCE_URL'].chomp('/')}/api/public/guide_sync/approved")
      uri.query = URI.encode_www_form({ since: since, tours_since: tours_since }.compact_blank)
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https', open_timeout: 10, read_timeout: 30) do |http|
        http.get(uri.request_uri, 'X-Guide-Sync-Token' => ENV['GUIDE_SYNC_TOKEN'], 'Accept' => 'application/json')
      end
      return [] unless response.is_a?(Net::HTTPSuccess)

      JSON.parse(response.body)
    rescue StandardError => e
      Rails.logger.warn("[Guide::ApprovedHelpSync] #{e.class}: #{e.message}")
      []
    end

    def latest_snapshot
      @latest_snapshot ||= Knowledge::Snapshot.where(source: Guide::ReleaseWatcher::SOURCE).order(snapshot_at: :desc).first ||
                           Knowledge::Snapshot.create!(source: Guide::ReleaseWatcher::SOURCE, snapshot_at: Time.current, modules_hash: 'empty')
    end

    def copy(remote)
      existing = Knowledge::ChangeQueueItem.where("context ->> 'staging_item_id' = ?", remote['id'].to_s).first
      return recopy(existing, remote) if existing

      latest_snapshot.change_queue_items.create!(
        change_type: remote['change_type'], entity_type: remote['entity_type'], entity_key: remote['entity_key'],
        new_value: remote['new_value'], drafts: remote['drafts'] || {}, draft_status: 'drafted', status: 'pending',
        context: { 'source' => 'staging', 'staging_item_id' => remote['id'].to_s, 'commit_shas' => Array(remote['commit_shas']) }
      )
    end

    # Approved again or edited on staging: take the new wording. A copy already
    # published goes back in line and publishes over what it made before.
    def recopy(existing, remote)
      return if existing.drafts == (remote['drafts'] || {}) && existing.new_value == remote['new_value']

      existing.update!(drafts: remote['drafts'] || {}, new_value: remote['new_value'],
                       status: existing.status == 'auto_applied' ? 'pending' : existing.status)
    end

    def pending_tours
      value = Setting.get('Platform', 0, PENDING_TOURS, {})
      value.is_a?(Hash) ? value : {}
    end

    def queue_tours(tours)
      return if tours.empty?

      pending = pending_tours
      tours.each { |t| pending["#{t['module_key']}/#{t['key']}"] = t }
      Setting.set('Platform', 0, PENDING_TOURS, pending)
    end

    # Every marker the latest build has: data-tour markers and form fields
    # ('#id') on pages, and the menu, section and tab anchors the Atlas walks.
    def known_markers
      atlas = latest_snapshot.atlas || {}
      walks = Array(atlas['entries']).flat_map { |e| Array(e['where']).map { |w| w['anchor'] } }
      (Array(atlas['markers']&.keys) + walks).compact.to_set
    end

    def tour_ready?(remote, known)
      Array(remote['steps']).all? do |step|
        marker = self.class.marker_for(step['selector'])
        marker.nil? || known.include?(marker)
      end
    end

    # The Atlas name for a step's selector, nil when it names no marker.
    def self.marker_for(selector)
      case selector.to_s
      when /\A\[data-tour="([^"]+)"\]\z/ then Regexp.last_match(1)
      when /\A\[id="([^"]+)"\]\z/, /\A#([\w-]+)\z/ then "##{Regexp.last_match(1)}"
      end
    end

    def apply_tour(remote)
      mod = remote['module_key'].present? ? Knowledge::Module.find_by(key: remote['module_key']) : nil
      return if remote['module_key'].present? && mod.nil?

      Tour.transaction do
        tour = Tour.find_or_initialize_by(knowledge_module_id: mod&.id, key: remote['key'])
        tour.assign_attributes(remote.slice('name', 'description', 'trigger_type', 'trigger_route', 'is_active', 'position').compact)
        tour.save!
        steps = Array(remote['steps']).map { |st| st.slice(*STEP_FIELDS) }
        unless tour.steps.map { |st| st.slice(*STEP_FIELDS).transform_values(&:presence) } == steps.map { |st| st.transform_values(&:presence) }
          tour.steps.destroy_all
          steps.each { |st| tour.steps.create!(st) }
        end
        # Approved on staging by the person who played it. Set last: changing
        # the steps above clears a tour's approval.
        tour.reload.update_columns(approved_at: Time.zone.parse(remote['approved_at'].to_s) || Time.current, approved_by_id: nil)
      end
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
