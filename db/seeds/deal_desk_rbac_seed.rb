# frozen_string_literal: true

# Deal Desk RBAC backfill. Resource/Action seed_defaults are idempotent and add the new
# deal_desk resource + write/quote/configure/transfer_unit actions. Existing system roles
# are NOT re-seeded by Role.seed_defaults (it returns early once roles exist), so this
# grants the deal_desk permissions to existing roles by key — covering both global system
# roles (company_id nil) and any company-specific roles sharing those keys.
#
# Default config (Section 25): reps build/quote/compare freely; configure + transfer_unit
# are manager-only. All grants use scope 'all' (the controller authorizes with default
# scope 'all'; location filtering is applied operationally).

puts '🔐 Backfilling Deal Desk RBAC...'

Resource.seed_defaults
Action.seed_defaults

deal_desk = Resource.find_by!(key: 'deal_desk')
all_scope = Scope.find_by!(key: 'all')

grant = lambda do |role, action_keys|
  Action.where(key: action_keys).each do |action|
    RolePermission.find_or_create_by!(role: role, resource: deal_desk, action: action, scope: all_scope, granted: true)
  end
end

REP_ACTIONS     = %w[read write quote].freeze
MANAGER_ACTIONS = %w[read write quote configure transfer_unit].freeze

rep_roles     = %w[sales_rep crm_specialist]
manager_roles = %w[company_manager location_manager location_admin company_admin]
staff_roles   = %w[company_staff location_staff]

Role.where(key: rep_roles).find_each     { |r| grant.call(r, REP_ACTIONS) }
Role.where(key: manager_roles).find_each { |r| grant.call(r, MANAGER_ACTIONS) }
Role.where(key: staff_roles).find_each   { |r| grant.call(r, %w[read]) }

puts "   ✅ deal_desk resource position: #{deal_desk.position}"
puts "   ✅ reps (#{rep_roles.join(', ')}): #{REP_ACTIONS.join('/')}"
puts "   ✅ managers (#{manager_roles.join(', ')}): #{MANAGER_ACTIONS.join('/')}"
puts "   ✅ staff (#{staff_roles.join(', ')}): read"
