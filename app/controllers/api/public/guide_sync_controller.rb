# frozen_string_literal: true

# Help approved on staging, for production to copy (backlog E75, "approve
# once"). Production's Guide::ApprovedHelpSync calls this with the shared
# GUIDE_SYNC_TOKEN; without the token set on this server it answers nothing.
class Api::Public::GuideSyncController < ApplicationController
  skip_before_action :authenticate

  # GET /api/public/guide_sync/approved?since=ISO8601
  def approved
    token = ENV['GUIDE_SYNC_TOKEN'].to_s
    given = request.headers['X-Guide-Sync-Token'].to_s
    unless token.present? && ActiveSupport::SecurityUtils.secure_compare(token, given)
      return render(json: { error: 'not allowed' }, status: :unauthorized)
    end

    since = parse_time(params[:since])
    render json: { items: help_since(since), tours: tours_since(parse_time(params[:tours_since])) }
  end

  private

  def parse_time(value)
    (Time.zone.parse(value.to_s) rescue nil) || Time.at(0)
  end

  # Approved help, including help approved again and articles edited in place
  # since it was approved, so a correction on staging reaches production too.
  # `changed_at` is the cursor production keeps.
  def help_since(since)
    scope = Knowledge::ChangeQueueItem.includes(:snapshot).where(status: 'approved', entity_type: %w[atlas_entry gap release])
    edited = Knowledge::Article.where('updated_at > ?', since).select(:id)
    items = scope.where('reviewed_at > ?', since)
                 .or(scope.where(published_article_id: edited)).or(scope.where(published_note_id: edited)).to_a
    articles = Knowledge::Article.where(id: items.flat_map { |i| [i.published_article_id, i.published_note_id] }.compact).index_by(&:id)
    items.map { |i| help_json(i, articles) }.sort_by { |h| h[:changed_at] }.first(200)
  end

  def help_json(item, articles)
    article = articles[item.published_article_id]
    note = articles[item.published_note_id]
    {
      id: item.id, entity_type: item.entity_type, change_type: item.change_type, entity_key: item.entity_key,
      new_value: item.new_value, drafts: current_drafts(item, article, note), reviewed_at: item.reviewed_at,
      changed_at: [item.reviewed_at, article&.updated_at, note&.updated_at].compact.max,
      # A release's notes cover the commits of that staging build.
      commit_shas: item.entity_type == 'release' ? Array(item.snapshot&.commits).map { |c| c['sha'] } : []
    }
  end

  # The drafts as published now: an article edited after approval wins.
  def current_drafts(item, article, note)
    drafts = (item.drafts || {}).deep_dup
    if article
      drafts['article'] = (drafts['article'] || {}).merge('title' => article.title, 'excerpt' => article.excerpt, 'content' => article.content)
    end
    if note && item.entity_type == 'release'
      drafts.merge!('title' => note.title, 'notes' => note.content)
    elsif note
      drafts['whats_new'] = note.content
    end
    drafts
  end

  # Tours played and approved on staging, with their steps, so production
  # does not have to approve them again (Guide::ApprovedHelpSync).
  def tours_since(since)
    Tour.approved.where('approved_at > ?', since).includes(:knowledge_module, :steps).order(:approved_at).limit(100).map do |t|
      {
        key: t.key, module_key: t.knowledge_module&.key, name: t.name, description: t.description,
        trigger_type: t.trigger_type, trigger_route: t.trigger_route, is_active: t.is_active, position: t.position,
        approved_at: t.approved_at,
        steps: t.steps.map { |s| s.slice(*Guide::ApprovedHelpSync::STEP_FIELDS) }
      }
    end
  end
end
