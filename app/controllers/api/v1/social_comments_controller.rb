# frozen_string_literal: true

class Api::V1::SocialCommentsController < ApplicationController
  before_action :set_company_scope
  before_action :set_comment, only: %i[show reply destroy hide unhide]

  MAX_PER_PAGE = 100

  # GET /api/v1/social-comments
  def index
    return unless authorize_action!('social_posts', 'read')

    # Hiding used to drop a comment out of every view, because `active` means
    # status 'active' and hide sets 'hidden'. There was then no way to find it
    # again, let alone unhide it. `status=hidden` makes them reachable.
    scope = params[:status] == 'hidden' ? @company.social_comments.hidden : @company.social_comments.active
    scope = scope.where(social_post_id: params[:post_id]) if params[:post_id].present?
    scope = scope.unread                                   if params[:unread] == 'true'
    scope = scope.top_level                                if params[:top_level] == 'true'
    scope = scope.order(commented_at: :desc)

    total    = scope.count
    page     = [(params[:page] || 1).to_i, 1].max
    per_page = [[((params[:per_page] || 25).to_i), MAX_PER_PAGE].min, 1].max

    comments = scope.offset((page - 1) * per_page).limit(per_page)

    render json: {
      comments: comments.map { |c| comment_json(c) },
      meta: {
        total:        total,
        page:         page,
        per_page:     per_page,
        total_pages:  (total.to_f / per_page).ceil,
        unread_count: @company.social_comments.active.unread.count
      }
    }
  end

  # GET /api/v1/social-comments/:id
  def show
    return unless authorize_action!('social_posts', 'read')

    @comment.update_column(:read_at, Time.current) if @comment.read_at.nil?

    replies = @company.social_comments.active
                      .replies_to(@comment.external_comment_id)
                      .order(:commented_at)

    render json: {
      comment: comment_json(@comment),
      replies: replies.map { |r| comment_json(r) }
    }
  end

  # POST /api/v1/social-comments/:id/reply
  def reply
    return unless authorize_action!('social_posts', 'update')

    message = params[:message].to_s
    return render json: { error: 'Message is required' }, status: :bad_request if message.blank?

    integration = FacebookIntegration.current_for(@company)
    return render json: { error: 'No Facebook page connected' }, status: :unprocessable_entity unless integration

    begin
      result = MetaGraphApi.reply_to_comment(
        @comment.external_comment_id,
        integration.page_access_token,
        message: message
      )
    rescue MetaGraphApi::ExpiredTokenError
      integration.update(status: 'expired')
      return render json: { error: 'Facebook token expired. Reconnect in Settings.' }, status: :unprocessable_entity
    rescue MetaGraphApi::Error => e
      return render json: { error: "Failed to reply: #{e.message}" }, status: :unprocessable_entity
    end

    external_id = result.is_a?(Hash) ? result['id'] : nil
    return render json: { error: 'Meta did not return a comment id' }, status: :bad_gateway if external_id.blank?

    reply_comment = @company.social_comments.create!(
      social_post_id:      @comment.social_post_id,
      external_comment_id: external_id,
      external_post_id:    @comment.external_post_id,
      platform:            @comment.platform,
      author_name:         integration.page_name.presence || @company.name,
      author_id:           integration.page_id,
      message:             message,
      parent_comment_id:   @comment.external_comment_id,
      is_reply:            true,
      is_from_page:        true,
      status:              'active',
      replied_by_user_id:  current_user&.id,
      commented_at:        Time.current,
      read_at:             Time.current
    )

    render json: comment_json(reply_comment), status: :created
  end

  # DELETE /api/v1/social-comments/:id
  def destroy
    return unless authorize_action!('social_posts', 'delete')

    integration = FacebookIntegration.current_for(@company)
    if integration
      begin
        if @comment.is_from_page?
          MetaGraphApi.delete_comment(@comment.external_comment_id, integration.page_access_token)
        else
          MetaGraphApi.hide_comment(@comment.external_comment_id, integration.page_access_token)
        end
      rescue MetaGraphApi::Error => e
        Rails.logger.warn "[SocialComments#destroy] Meta call failed (continuing soft-delete): #{e.message}"
      end
    end

    @comment.update!(status: 'deleted', is_deleted: true)
    head :no_content
  end

  # POST /api/v1/social-comments/:id/hide
  #
  # Hiding is a moderation action on Facebook, not a local flag. It used to
  # swallow a Graph failure and mark the row hidden anyway, which told the user
  # a comment was hidden while it was still public on the Page.
  #
  # Worth knowing when testing: Facebook keeps a hidden comment visible to its
  # author and their friends. Checking as the person who wrote it will always
  # look like nothing happened.
  def hide
    return unless authorize_action!('social_posts', 'update')

    result = set_comment_hidden(@comment, true)
    return render json: { error: result[:error] }, status: :unprocessable_entity unless result[:ok]

    @comment.update!(status: 'hidden')
    render json: comment_json(@comment)
  end

  # POST /api/v1/social-comments/:id/unhide
  #
  # The counterpart hide never had. MetaGraphApi.unhide_comment existed but
  # nothing called it, and a hidden comment dropped out of every list, so
  # hiding one was irreversible from inside the app.
  def unhide
    return unless authorize_action!('social_posts', 'update')

    result = set_comment_hidden(@comment, false)
    return render json: { error: result[:error] }, status: :unprocessable_entity unless result[:ok]

    @comment.update!(status: 'active')
    render json: comment_json(@comment)
  end

  # POST /api/v1/social-comments/mark_all_read
  # POST /api/v1/social-comments/sync
  #
  # The background sweep runs every 15 minutes, so a comment left just now is
  # not in the inbox yet even though the Page card already counts it (that
  # count is read live from Graph). This pulls the recent posts immediately.
  def sync
    return unless authorize_action!('social_posts', 'read')

    integration = FacebookIntegration.current_for(@company)
    return render json: { error: 'No Facebook page connected' }, status: :unprocessable_entity unless integration

    begin
      synced, new_count = SyncSocialCommentsJob.new.sync_now(@company)
    rescue MetaGraphApi::ExpiredTokenError
      return render json: { error: 'Facebook token expired. Reconnect in Settings.' }, status: :unprocessable_entity
    rescue MetaGraphApi::RateLimitError
      return render json: { error: 'Facebook is rate limiting us. Try again in a few minutes.' }, status: :too_many_requests
    rescue MetaGraphApi::Error => e
      return render json: { error: "Could not reach Facebook: #{e.message}" }, status: :unprocessable_entity
    end

    render json: {
      synced:      synced,
      new:         new_count,
      unread_count: @company.social_comments.active.unread.count
    }
  end

  def mark_all_read
    return unless authorize_action!('social_posts', 'read')

    @company.social_comments.active.unread.update_all(read_at: Time.current)
    render json: { success: true }
  end

  private

  def set_comment
    @comment = @company.social_comments.find_by(id: params[:id])
    render json: { error: 'Not found' }, status: :not_found unless @comment
  end

  # Flips a comment's hidden state on Facebook. Returns {ok:} / {ok:, error:}
  # so the caller can refuse the local change rather than claim a moderation
  # action that never reached the Page.
  def set_comment_hidden(comment, hidden)
    integration = FacebookIntegration.current_for(@company)
    return { ok: false, error: 'No Facebook page connected. Reconnect in Settings > Integrations.' } unless integration

    if hidden
      MetaGraphApi.hide_comment(comment.external_comment_id, integration.page_access_token)
    else
      MetaGraphApi.unhide_comment(comment.external_comment_id, integration.page_access_token)
    end
    { ok: true }
  rescue MetaGraphApi::ExpiredTokenError
    integration&.update(status: 'expired')
    { ok: false, error: 'Facebook token expired. Reconnect in Settings > Integrations.' }
  rescue MetaGraphApi::NotFoundError
    { ok: false, error: 'That comment no longer exists on Facebook.' }
  rescue MetaGraphApi::Error => e
    verb = hidden ? 'hide' : 'unhide'
    { ok: false, error: "Facebook refused to #{verb} the comment: #{e.message}" }
  end

  def comment_json(c)
    {
      id:                  c.id,
      social_post_id:      c.social_post_id,
      external_comment_id: c.external_comment_id,
      external_post_id:    c.external_post_id,
      platform:            c.platform,
      author_name:         c.author_name,
      author_id:           c.author_id,
      author_profile_pic:  c.author_profile_pic,
      message:             c.message,
      parent_comment_id:   c.parent_comment_id,
      is_reply:            c.is_reply,
      is_from_page:        c.is_from_page,
      status:              c.status,
      replied_by_user:     serialize_user(c.replied_by_user),
      commented_at:        c.commented_at,
      read_at:             c.read_at,
      created_at:          c.created_at,
      post_headline:       c.social_post&.headline,
      reply_count:         c.is_reply ? 0 : @company.social_comments.active.replies_to(c.external_comment_id).count
    }
  end

  def serialize_user(user)
    return nil unless user
    { id: user.id, name: user.full_name.to_s.strip.presence || user.email }
  end
end
