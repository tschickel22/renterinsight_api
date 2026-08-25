# frozen_string_literal: true

# Who is on a tenant site right now, and who was.
#
# Deliberately cross-tenant: this is the platform operator's view, and its value
# is precisely that it spans every dealer. require_platform_admin! checks
# original_user, so it stays closed during impersonation rather than inheriting
# whichever tenant is being impersonated.
#
# Presence is derived from last_seen_at rather than pushed. cable.yml uses the
# async adapter in every environment, which is in-process only, so a broadcast
# would reach whichever process happened to hold the connection and no other.
# The client polls; it looks the same and it is honest about what it is.
class Api::Admin::LiveVisitorsController < ApplicationController
  before_action :require_platform_admin!

  # How long after its last beacon a visit still counts as present.
  #
  # The beacon sends a keepalive every 20 seconds while its tab is visible, so
  # this is three missed beats. Tighter and a visitor flickers out between
  # heartbeats on a slow connection; looser and the list keeps showing people
  # who closed the tab a minute ago, which is worse than showing nobody.
  PRESENT_WITHIN = 90.seconds

  # An app user is present for longer than a website visitor.
  #
  # A visitor's browser reports every twenty seconds whether or not they do
  # anything. A user reading a deal for four minutes makes no requests at all,
  # so the same ninety seconds would show them leaving and coming back.
  USER_PRESENT_WITHIN = 5.minutes

  # GET /api/admin/live_visitors
  #
  # Both kinds in one feed, each tagged. They answer different halves of the
  # same question and reading them on two screens means missing the moment a
  # dealer's own staff are in the product while their customer is on their site.
  def index
    visits = base_scope.where(last_seen_at: PRESENT_WITHIN.ago..)
                       .order(last_seen_at: :desc)
                       .limit(200)

    users = active_users.where(last_active_at: USER_PRESENT_WITHIN.ago..)
                        .order(last_active_at: :desc)
                        .limit(200)

    items = visits.map { |v| row(v) } + users.map { |u| user_row(u) }

    render json: {
      items: items.sort_by { |i| i[:last_seen_at] || Time.at(0) }.reverse,
      present_within_seconds: PRESENT_WITHIN.to_i,
      user_present_within_seconds: USER_PRESENT_WITHIN.to_i
    }
  end

  # GET /api/admin/live_visitors/history
  #
  # The same rows once they are no longer present. Someone who has just left is
  # usually the interesting one: a live view alone means noticing a visitor only
  # if you happen to be looking at the moment they are there.
  def history
    kind = params[:kind].presence

    if kind == 'user'
      users = active_users.where(last_active_at: ...USER_PRESENT_WITHIN.ago)
                          .order(last_active_at: :desc)
      return render json: paginated(users) { |u| user_row(u) }
    end

    visits = base_scope.where(last_seen_at: ...PRESENT_WITHIN.ago)
                       .order(last_seen_at: :desc)

    visits = visits.where(last_seen_at: parse_time(params[:from])..) if params[:from].present?
    visits = visits.where(converted: true) if truthy?(params[:converted])
    visits = visits.identified if truthy?(params[:identified])

    render json: paginated(visits) { |v| row(v) }
  end

  private

  def paginated(scope)
    page = [params[:page].to_i, 1].max
    per_page = [[params[:per_page].to_i, 1].max, 200].min
    total = scope.count

    {
      items: scope.offset((page - 1) * per_page).limit(per_page).map { |r| yield(r) },
      meta: { total: total, page: page, per_page: per_page,
              total_pages: (total.to_f / per_page).ceil }
    }
  end

  # Staff working in the product, as opposed to visitors on a dealer's website.
  #
  # Never recorded activity before now, so a user who has not signed in since
  # this shipped simply has none rather than appearing to have been idle since
  # the beginning of time.
  def active_users
    User.where.not(last_active_at: nil).includes(:company)
  end

  def user_row(user)
    {
      kind: 'app_user',
      id: "user-#{user.id}",
      company: user.company&.name,
      company_id: user.company_id,
      # Reusing the visitor's key so one sorted feed needs no special casing.
      last_seen_at: user.last_active_at,
      first_seen_at: user.last_sign_in_at,
      page_path: user.last_active_path,
      page_title: nil,
      is_landing_page: false,
      visitor: nil,
      source: 'app',
      device: nil,
      country: nil,
      region: nil,
      duration_ms: nil,
      max_scroll_depth: nil,
      converted: false,
      identity: {
        type: 'User',
        id: user.id,
        name: [user.first_name, user.last_name].compact.join(' ').presence || user.email,
        email: user.email,
        role: user.role
      }
    }
  end

  # Bots excluded, as everywhere else. A crawler that runs JavaScript would
  # otherwise sit in the live view looking like a person.
  def base_scope
    PageVisit.real
             .includes(:company, website_page: :website)
             .where.not(website_page_id: nil)
  end

  def row(visit)
    page = visit.website_page

    {
      kind: 'website_visitor',
      id: visit.id,
      company: visit.company&.name,
      company_id: visit.company_id,
      page_id: page&.id,
      page_title: page&.title,
      page_path: page&.path,
      is_landing_page: page&.landing_page?,
      # Enough to tell two anonymous visitors apart on screen without putting a
      # tracking identifier in front of an operator.
      visitor: visit.visitor_token.to_s.last(6),
      source: Marketing::VisitSource.label(utm_source: visit.utm_source, referrer: visit.referrer),
      utm_campaign: visit.utm_campaign,
      device: visit.device_type,
      country: visit.country,
      region: visit.try(:region),
      first_seen_at: visit.first_seen_at,
      last_seen_at: visit.last_seen_at,
      duration_ms: visit.duration_ms,
      max_scroll_depth: visit.max_scroll_depth,
      converted: visit.converted,
      # The thing a third-party live view cannot tell you: which of these people
      # you already know.
      identity: identity_for(visit)
    }
  end

  def identity_for(visit)
    return nil if visit.identified_entity_id.blank?

    entity = visit.identified_entity
    return nil if entity.nil?

    {
      type: visit.identified_entity_type,
      id: visit.identified_entity_id,
      name: entity.try(:full_name).presence || entity.try(:name).presence ||
            [entity.try(:first_name), entity.try(:last_name)].compact.join(' ').presence
    }
  rescue StandardError => e
    # A deleted lead must not take the whole view down with it.
    Rails.logger.warn("[LiveVisitors] identity lookup failed for visit #{visit.id}: #{e.message}")
    nil
  end

  def truthy?(value)
    ActiveModel::Type::Boolean.new.cast(value).present?
  end

  def parse_time(value)
    Time.zone.parse(value.to_s)
  rescue ArgumentError, TypeError
    nil
  end
end
