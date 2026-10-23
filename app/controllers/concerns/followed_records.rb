# frozen_string_literal: true

# Followers (backlog E86) in the lead, account, contact and deal controllers:
# a location-restricted rep also sees what they follow, and every list takes
# the same multi-select owner / follower / "mine" filters.
module FollowedRecords
  extend ActiveSupport::Concern

  private

  # `located` is `scope` narrowed to the rep's locations. Records they follow
  # are added back whatever their location.
  def or_followed(scope, located)
    located.or(scope.followed_by(current_user.id))
  end

  # Comma list or repeated param, blanks and 'all' dropped.
  def list_param(value)
    Array(value).flat_map { |v| v.to_s.split(',') }.map(&:strip).reject { |v| v.blank? || v == 'all' }
  end

  # owner_ids:    user ids, plus 'unassigned' (or the older 'null') for no owner
  # owner_id:     the older single-value form, still accepted
  # follower_ids: records any of these users follow
  # mine=true:    records I own or follow (deals also count the legacy rep)
  def apply_follower_filters(scope, filters = params)
    table = scope.klass.table_name
    owner_values = list_param(filters[:owner_ids]).presence || list_param(filters[:owner_id])
    if owner_values.any?
      unassigned = owner_values.intersect?(%w[unassigned null])
      ids = owner_values.grep(/\A\d+\z/).map(&:to_i)
      clause = scope.where(owner_id: ids)
      clause = clause.or(scope.where(owner_id: nil)) if unassigned
      scope = ids.empty? ? scope.where(owner_id: nil) : clause
    end

    follower_ids = list_param(filters[:follower_ids]).grep(/\A\d+\z/).map(&:to_i)
    scope = scope.followed_by(follower_ids) if follower_ids.any?

    if ActiveModel::Type::Boolean.new.cast(filters[:mine])
      me = current_user.id
      mine = scope.where(owner_id: me).or(scope.followed_by(me))
      if table == 'deals'
        mine = mine.or(scope.where(user_id: me)).or(scope.where(primary_salesperson_id: me))
      end
      scope = mine
    end

    scope
  end
end
