# frozen_string_literal: true

module Guide
  # Once a week (Monday), the help for what changed that week (backlog E75).
  #
  # A week holds dozens of small staging deploys, and drafting help for each
  # one buried the few changes a dealer would notice. This compares the latest
  # build with the one the last digest ended on, so a place added and changed
  # three times is one change and a place added and removed is none. Claude
  # first decides what a dealer would notice and writes the week's notes; help
  # is drafted only for those places, and a place that already has help gets
  # that help rewritten rather than a second copy. Then it emails whoever
  # reviews it, with the tours waiting for approval.
  class WeeklyDigest
    def initialize(now: Time.current, drafter: Guide::ReleaseDrafter, force: false)
      @now = now
      @drafter = drafter
      @force = force
    end

    def self.week_key(time = Time.current)
      time.to_date.beginning_of_week(:monday).to_s
    end

    def self.recipient
      ENV['GUIDE_DIGEST_EMAIL'].presence || Brand.current.support_email
    end

    # Returns the week's release item, or nil when there was nothing to do.
    def run
      # Production copies what staging approves; it never drafts.
      return nil if Guide::ApprovedHelpSync.configured?

      head = snapshots.first
      return nil unless head
      return nil if !@force && weekly_items.where("context ->> 'week' = ?", week).exists?

      base = base_snapshot(head)
      changes = base && base != head ? diff(base, head) : []
      commits = commits_between(base, head)

      release = head.change_queue_items.create!(
        change_type: 'modified', entity_type: 'release', entity_key: "week-#{week}#{@force ? "-#{@now.to_i}" : ''}",
        new_value: { 'commit_count' => commits.size, 'change_count' => changes.size },
        context: { 'weekly' => true, 'week' => week, 'base_snapshot_id' => base&.id, 'commits' => commits,
                   'changes' => changes.map { |c| summary(c) } }
      )
      draft(release)

      keep = Array(release.reload.drafts['dealer_visible_keys'])
      changes.select { |c| keep.include?(c[:key]) }.each { |c| draft(queue(head, c)) }

      GuideDigestMailer.weekly(release.id).deliver_later
      release
    end

    private

    def week
      @week ||= self.class.week_key(@now)
    end

    def snapshots
      Knowledge::Snapshot.where(source: Guide::ReleaseWatcher::SOURCE).order(snapshot_at: :desc)
    end

    def weekly_items
      Knowledge::ChangeQueueItem.where(entity_type: 'release').where("context ->> 'weekly' = 'true'")
    end

    # Where the last digest ended; the first one looks back a week.
    def base_snapshot(head)
      last = weekly_items.where.not(knowledge_snapshot_id: head.id).order(created_at: :desc).first
      return last.snapshot if last

      snapshots.where('snapshot_at <= ?', @now - 7.days).first || snapshots.last
    end

    # Places only platform admins see are not dealer help.
    def dealer_entries(snapshot)
      Array(snapshot.atlas['entries']).reject { |e| Guide::TourDrafter.platform_only?(e) }.index_by { |e| e['key'] }
    end

    def diff(base, head)
      before = dealer_entries(base)
      after = dealer_entries(head)
      compared = Guide::ReleaseWatcher::COMPARED
      changes = (after.keys - before.keys).map { |k| { change: 'added', key: k, old: nil, new: after[k] } }
      changes += (before.keys - after.keys).select { |k| help_for(k) }.map { |k| { change: 'removed', key: k, old: before[k], new: nil } }
      changes + (after.keys & before.keys).filter_map do |k|
        next if after[k].slice(*compared) == before[k].slice(*compared)

        { change: 'modified', key: k, old: before[k], new: after[k] }
      end
    end

    def commits_between(base, head)
      list = snapshots.where(snapshot_at: (base ? base.snapshot_at : Time.at(0))..head.snapshot_at)
      list = list.where.not(id: base.id) if base
      list.flat_map { |s| Array(s.commits) }.uniq { |c| c['sha'] }.first(120)
    end

    def summary(change)
      entry = Guide::Copy.render_deep(change[:new] || change[:old] || {})
      { 'change' => change[:change], 'key' => change[:key], 'title' => entry['title'],
        'where' => Array(entry['breadcrumb']).join(' > ') }
    end

    # The help an earlier approval made for this place, if any.
    def help_for(key)
      @help_for ||= {}
      return @help_for[key] if @help_for.key?(key)

      @help_for[key] = Knowledge::ChangeQueueItem.where(entity_type: 'atlas_entry', entity_key: key, status: 'approved')
                                                 .where('published_article_id IS NOT NULL OR published_tour_id IS NOT NULL')
                                                 .order(reviewed_at: :desc).first
    end

    def queue(head, change)
      prior = help_for(change[:key])
      head.change_queue_items.create!(
        change_type: change[:change], entity_type: 'atlas_entry', entity_key: change[:key],
        old_value: change[:old], new_value: change[:new],
        # Approving updates what the earlier approval made instead of adding a copy.
        published_article_id: prior&.published_article_id, published_tour_id: prior&.published_tour_id,
        published_note_id: nil,
        # Retiring help for a removed place is a person's call, not a draft.
        draft_status: change[:change] == 'removed' ? 'skipped' : 'pending',
        context: { 'weekly' => true, 'week' => week }
      )
    end

    def draft(item)
      return item if item.draft_status == 'skipped'

      @drafter.new(item).draft!
      item
    rescue StandardError => e
      Rails.logger.warn("[Guide::WeeklyDigest] #{item.entity_type} #{item.entity_key}: #{e.class} #{e.message}")
      item
    end
  end
end
