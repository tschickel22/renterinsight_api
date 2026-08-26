# frozen_string_literal: true

# Platform-side user monitoring. Never exposed to tenants: there is no
# tenant-facing route to any of this, and there must not be one.
class Api::Platform::UserWatchesController < ApplicationController
  before_action :require_platform_admin!
  before_action :set_watch, only: %i[show destroy report timeline]

  # GET /api/platform/user_watches
  def index
    watches = UserActivityWatch.order(active: :desc, started_at: :desc).limit(100)
    render json: { items: watches.map { |w| summarize(w) } }
  end

  def show
    render json: summarize(@watch)
  end

  # POST /api/platform/user_watches
  def create
    user = User.find_by(id: params[:user_id])
    return render json: { error: 'User not found' }, status: :not_found if user.nil?

    if params[:reason].blank?
      return render json: { error: 'A reason is required. This is an audit record.' },
                    status: :unprocessable_entity
    end

    existing = UserActivityWatch.active_for(user.id)
    return render json: summarize(existing), status: :ok if existing

    watch = UserActivityWatch.create!(
      user_id: user.id,
      company_id: user.company_id,
      created_by_user_id: current_user.id,
      reason: params[:reason],
      active: true,
      started_at: Time.current
    )
    UserActivityWatch.reset_cache!

    render json: summarize(watch), status: :created
  end

  # DELETE /api/platform/user_watches/:id
  # Stops collection. Deliberately keeps the trail already gathered.
  def destroy
    @watch.update!(active: false, ended_at: Time.current)
    UserActivityWatch.reset_cache!

    render json: summarize(@watch).merge(message: 'Watch stopped. Captured trail retained.')
  end

  # GET /api/platform/user_watches/:id/report
  def report
    render json: UserActivityReport.new(
      @watch,
      since: parse_time(params[:since]),
      until_time: parse_time(params[:until])
    ).as_json
  end

  # GET /api/platform/user_watches/:id/timeline
  # The raw trail, with the gap to the previous navigation precomputed since
  # that is the column anyone reading this actually scans.
  def timeline
    scope = @watch.watched_requests.chronological
    scope = scope.navigations if params[:navigations_only].to_s == 'true'
    scope = scope.where('occurred_at >= ?', parse_time(params[:since])) if params[:since].present?
    rows  = scope.limit([(params[:limit] || 500).to_i, 5000].min).to_a

    previous = nil
    items = rows.map do |r|
      gap = previous ? (r.occurred_at - previous.occurred_at).to_f.round(1) : nil
      previous = r
      {
        occurred_at: r.occurred_at,
        gap_seconds: gap,
        method: r.http_method,
        path: r.path,
        controller_action: r.controller_action,
        status: r.status,
        duration_ms: r.duration_ms,
        ip_address: r.ip_address,
        is_poll: r.is_poll
      }
    end

    render json: { watch_id: @watch.id, count: items.size, items: items }
  end

  private

  def set_watch
    @watch = UserActivityWatch.find_by(id: params[:id])
    render json: { error: 'Watch not found' }, status: :not_found if @watch.nil?
  end

  def parse_time(value)
    return nil if value.blank?

    Time.zone.parse(value.to_s)
  rescue StandardError
    nil
  end

  def summarize(watch)
    {
      id: watch.id,
      user_id: watch.user_id,
      user_email: watch.user&.email,
      company_id: watch.company_id,
      company_name: watch.company&.name,
      reason: watch.reason,
      active: watch.active,
      started_at: watch.started_at,
      ended_at: watch.ended_at,
      created_by: watch.created_by&.email,
      captured_requests: watch.watched_requests.count
    }
  end
end
