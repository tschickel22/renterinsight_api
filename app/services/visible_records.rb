# frozen_string_literal: true

# The location rule the list pages apply, for code that runs without their
# controllers: the Import/Export builder (a background job) and the report
# engine. A non-admin on the RBAC system sees records at their assigned
# locations plus unassigned ones, and anything they follow. Mirrors the
# index actions of accounts, contacts, quotes and service tickets. Leads
# keep their own wider rule (LeadsController#base_leads_scope).
#
# Exports and reports must never show someone more than their lists would.
module VisibleRecords
  module_function

  def restrict(scope, user:, module_key: nil)
    return scope.none if user.nil?
    return scope unless user.uses_rbac? && !user.effective_admin?
    return scope unless scope.column_names.include?('location_id')

    perms = PermissionService.new(user)
    return scope if module_key.to_s == 'leads' && perms.can?('leads', 'read', 'all')

    location_ids = perms.accessible_location_ids
    # The lists do not narrow a user who has no assigned locations.
    return scope if location_ids.empty?

    table   = scope.table_name
    located = scope.where("#{table}.location_id IN (?) OR #{table}.location_id IS NULL", location_ids)
    scope.respond_to?(:followed_by) ? located.or(scope.followed_by(user.id)) : located
  end
end
