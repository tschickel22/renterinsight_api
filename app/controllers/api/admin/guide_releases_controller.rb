# frozen_string_literal: true

module Api
  module Admin
    # The release queue in Knowledge admin (backlog E75): what changed in each
    # frontend build, the help AI drafted for it, and approve, edit, redraft or
    # discard. Platform admins only.
    class GuideReleasesController < ApplicationController
      before_action :authenticate_user!
      before_action :require_platform_admin!
      before_action :set_item, only: %i[update approve reject redraft]

      # GET /api/admin/guide/releases
      def index
        snapshots = Knowledge::Snapshot.where(source: Guide::ReleaseWatcher::SOURCE)
                                       .order(snapshot_at: :desc).limit(20)
        items = Knowledge::ChangeQueueItem.where(knowledge_snapshot_id: snapshots.map(&:id))
                                          .order(:created_at)
                                          .group_by(&:knowledge_snapshot_id)
        render json: {
          atlas_url: Guide::ReleaseWatcher.atlas_url,
          pending_count: Knowledge::ChangeQueueItem.joins(:snapshot)
                                                   .where(knowledge_snapshots: { source: Guide::ReleaseWatcher::SOURCE })
                                                   .pending.count,
          releases: snapshots.map do |s|
            {
              id: s.id, snapshot_at: s.snapshot_at, commit: s.commit_sha, branch: s.atlas['branch'],
              entries: s.features_count, commits: Array(s.commits).map { |c| c.slice('sha', 'subject', 'date') },
              baseline: s == snapshots.last && Knowledge::Snapshot.where(source: Guide::ReleaseWatcher::SOURCE).count == 1,
              items: Array(items[s.id]).map { |i| item_json(i) }
            }
          end
        }
      end

      # POST /api/admin/guide/releases/check
      # Look for a new build now instead of waiting for the schedule.
      def check
        snapshot = Guide::ReleaseWatcher.new.run
        render json: { found: snapshot.present?, snapshot_id: snapshot&.id, atlas_url: Guide::ReleaseWatcher.atlas_url }
      end

      # PATCH /api/admin/guide/releases/items/:id  { drafts: {...} }
      def update
        drafts = params.require(:drafts).permit!.to_h.deep_stringify_keys
        @item.update!(drafts: @item.drafts.deep_merge(drafts))
        render json: item_json(@item)
      end

      # POST /api/admin/guide/releases/items/:id/approve
      def approve
        Guide::ReleasePublisher.new(@item, original_user).publish!
        render json: item_json(@item.reload)
      rescue ActiveRecord::RecordInvalid => e
        render json: { error: e.record.errors.full_messages.to_sentence }, status: :unprocessable_entity
      end

      # POST /api/admin/guide/releases/items/:id/reject
      def reject
        @item.reject!(original_user)
        render json: item_json(@item)
      end

      # POST /api/admin/guide/releases/items/:id/redraft
      def redraft
        @item.update!(draft_status: 'pending', draft_error: nil)
        Guide::DraftReleaseItemJob.perform_later(@item.id)
        render json: item_json(@item)
      end

      private

      def set_item
        @item = Knowledge::ChangeQueueItem.find_by(id: params[:id])
        render json: { error: 'not found' }, status: :not_found unless @item
      end

      def item_json(item)
        entry = item.new_value || item.old_value || {}
        {
          id: item.id, change_type: item.change_type, entity_type: item.entity_type, key: item.entity_key,
          title: entry['title'], kind: entry['kind'], route: entry['route'], breadcrumb: entry['breadcrumb'],
          status: item.status, draft_status: item.draft_status, draft_error: item.draft_error, drafts: item.drafts,
          published_at: item.published_at, published_article_id: item.published_article_id,
          published_tour_id: item.published_tour_id, published_note_id: item.published_note_id,
          # A removed place: articles that still send people there.
          related_articles: item.change_type == 'removed' ? related_articles(entry) : []
        }
      end

      def related_articles(entry)
        route = entry['route'].to_s.split('?').first
        return [] if route.blank? || route == '/'

        Knowledge::Article.where('content ILIKE ?', "%#{Knowledge::Article.sanitize_sql_like(route)}%")
                          .limit(10).map { |a| { id: a.id, slug: a.slug, title: a.title } }
      end
    end
  end
end
