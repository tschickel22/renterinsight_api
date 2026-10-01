# frozen_string_literal: true

# The one rule for "may this person see records at this location", written to
# match what the app's own screens already do, so search, notes and lead
# activities are neither stricter nor looser than opening the record itself:
#
# - companies without RBAC, and admins, see every location;
# - a lead-wide "read all" permission sees every lead (the leads screen);
# - otherwise the person's accessible locations, plus records with no
#   location; a person with no locations configured falls back to the whole
#   company, as every list screen does today;
# - inventory includes locations that share a lot (inventory sharing groups).
module RecordLocationAccess
  extend ActiveSupport::Concern

  private

  def location_restricted_ids(resource = nil)
    return nil unless current_user&.uses_rbac?
    return nil if current_user.effective_admin?
    return nil if resource == 'leads' && permission_service.can?('leads', 'read', 'all')

    ids = permission_service.accessible_location_ids
    return nil if ids.blank?

    if resource == 'inventory' && @company.respond_to?(:expand_with_inventory_peers)
      ids = @company.expand_with_inventory_peers(ids)
    end
    Array(ids)
  end

  def location_scope(relation, resource = nil)
    return relation unless relation.klass.column_names.include?('location_id')

    ids = location_restricted_ids(resource)
    return relation if ids.nil?

    column = relation.klass.arel_table[:location_id]
    relation.where(column.in(ids).or(column.eq(nil)))
  end

  def record_location_accessible?(record, resource = nil)
    return true unless record.respond_to?(:location_id) && record.location_id.present?

    ids = location_restricted_ids(resource)
    ids.nil? || ids.include?(record.location_id)
  end
end
