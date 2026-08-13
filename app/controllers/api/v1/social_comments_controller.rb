# frozen_string_literal: true

class Api::V1::SocialCommentsController < ApplicationController
  before_action :set_company_scope
  before_action :set_comment, only: %i[show reply destroy hide unhide]

  MAX_PER_PAGE = 100

  # GET /api/v1/social-comments
  def index
    return unless authorize_action!('social_posts', 'read')

    # Hiding used to drop a comment out of every view, because `active` means
    # status 'active' and hide sets 'hidden'. The comment vanished on the next
    # reload and its Unhide button went with it.
    #
    # The default list now carries hidden comments too, badged and offering
    # Unhide. `status=hidden` isolates them; Unread deliberately does not, since
    # a comment you have already hidden is not waiting on a reply.
    # `status=removed` lists what has been taken down. Nothing is erased, so a
    # dealer can still see what they acted on, which Facebook itself will not
    # show them.
    scope = case params[:status]
            when 'hidden'  then @company.social_comments.hidden
            when 'removed' then @company.social_comments.removed
            else
              params[:unread] == 'true' ? @company.social_comments.active : @company.social_comments.visible
            end
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
  #
  # Facebook only lets a Page delete its own comments. Somebody else's is
  # hidden instead, which is the strongest action available to us, so Delete
  # means two different things depending on who wrote the comment. There is no
  # choice to offer: it is decided by authorship, not preference.
  #
  # Which of the two happened is recorded, because a hidden comment still looks
  # completely normal on Facebook to the person who wrote it. Without a record
  # there is nothing anywhere that says the dealer acted on it.
  def destroy
    return unless authorize_action!('social_posts', 'delete')

    remote = @comment.is_from_page? ? :delete : :hide
    result = moderate_on_facebook(@comment, remote)
    return render json: { error: result[:error] }, status: :unprocessable_entity unless result[:ok]

    @comment.update!(
      status:     'deleted',
      is_deleted: true,
      metadata:   moderation_metadata(@comment, remote: result[:already_gone] ? :already_gone : remote)
    )
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

    result = moderate_on_facebook(@comment, :hide)
    return render json: { error: result[:error] }, status: :unprocessable_entity unless result[:ok]

    @comment.update!(status: 'hidden', metadata: moderation_metadata(@comment, remote: :hide))
    render json: comment_json(@comment)
  end

  # POST /api/v1/social-comments/:id/unhide
  #
  # The counterpart hide never had. MetaGraphApi.unhide_comment existed but
  # nothing called it, and a hidden comment dropped out of every list, so
  # hiding one was irreversible from inside the app.
  def unhide
    return unless authorize_action!('social_posts', 'update')

    result = moderate_on_facebook(@comment, :unhide)
    return render json: { error: result[:error] }, status: :unprocessable_entity unless result[:ok]

    @comment.update!(status: 'active', metadata: moderation_metadata(@comment, remote: :unhide))
    render json: comment_json(@comment)
  end

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

  # POST /api/v1/social-comments/mark_all_read
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

  # Performs a moderation action on Facebook. Returns {ok:} / {ok:, error:} so
  # a caller can refuse the local change rather than claim an action that never
  # reached the Page.
  def moderate_on_facebook(comment, action)
    integration = FacebookIntegration.current_for(@company)
    return { ok: false, error: 'No Facebook page connected. Reconnect in Settings > Integrations.' } unless integration

    token = integration.page_access_token
    case action
    when :hide   then MetaGraphApi.hide_comment(comment.external_comment_id, token)
    when :unhide then MetaGraphApi.unhide_comment(comment.external_comment_id, token)
    when :delete then MetaGraphApi.delete_comment(comment.external_comment_id, token)
    end
    { ok: true }
  rescue MetaGraphApi::ExpiredTokenError
    integration&.update(status: 'expired')
    { ok: false, error: 'Facebook token expired. Reconnect in Settings > Integrations.' }
  rescue MetaGraphApi::NotFoundError
    # Already gone on Facebook, so the two sides agree. Not a failure, but the
    # record should not claim we were the ones who removed it.
    { ok: true, already_gone: true }
  rescue MetaGraphApi::Error => e
    { ok: false, error: "Facebook refused to #{action} the comment: #{e.message}" }
  end

  # What we did and when, kept on the row so the app can say so later. A hidden
  # comment is invisible as such on Facebook (its author still sees it exactly
  # as before), so this is the only place the action is recorded at all.
  def moderation_metadata(comment, remote:)
    base = comment.metadata.is_a?(Hash) ? comment.metadata.deep_stringify_keys : {}
    base.merge(
      'moderation' => {
        'on_facebook' => remote.to_s,
        'at'          => Time.current.iso8601,
        'by_user_id'  => current_user&.id,
        'by_name'     => current_user&.full_name || current_user&.email
      }
    ).deep_stringify_keys
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
      moderation:          moderation_json(c),
      replied_by_user:     serialize_user(c.replied_by_user),
      commented_at:        c.commented_at,
      read_at:             c.read_at,
      created_at:          c.created_at,
      post_headline:       c.social_post&.headline,
      reply_count:         c.is_reply ? 0 : @company.social_comments.active.replies_to(c.external_comment_id).count
    }
  end

  def moderation_json(comment)
    meta = comment.metadata.is_a?(Hash) ? comment.metadata.deep_stringify_keys : {}
    entry = meta['moderation']
    entry.is_a?(Hash) ? entry : nil
  end

  def serialize_user(user)
    return nil unless user
    { id: user.id, name: user.full_name.to_s.strip.presence || user.email }
  end
end
