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

    since = (Time.zone.parse(params[:since].to_s) rescue nil) || Time.at(0)
    items = Knowledge::ChangeQueueItem.includes(:snapshot)
                                      .where(status: 'approved', entity_type: %w[atlas_entry gap release])
                                      .where('reviewed_at > ?', since)
                                      .order(:reviewed_at).limit(200)
    render json: {
      items: items.map do |i|
        {
          id: i.id, entity_type: i.entity_type, change_type: i.change_type, entity_key: i.entity_key,
          new_value: i.new_value, drafts: i.drafts, reviewed_at: i.reviewed_at,
          # A release's notes cover the commits of that staging build.
          commit_shas: i.entity_type == 'release' ? Array(i.snapshot&.commits).map { |c| c['sha'] } : []
        }
      end
    }
  end
end
