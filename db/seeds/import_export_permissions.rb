# frozen_string_literal: true

# Grants data_import_export permissions to standard system roles.
# Run: bin/rails runner db/seeds/import_export_permissions.rb
#
# Allocation:
#   Company Administrator   → create, read, update, delete (full)
#   Company Manager         → create, read, update, delete (full)
#   Location Administrator  → create, read, update, delete (full)
#   Location Manager        → create, read, update
#   Inventory Manager       → create, read, update
#   Finance Staff           → create, read, update
#   CRM Specialist          → create, read, update
#   Sales Representative    → read
#   Company Staff           → read
#
# 'delete' covers rollback (rollback destroys created records).

resource = Resource.find_by!(key: 'data_import_export')
scope    = Scope.find_by!(key: 'all')
actions  = Action.where(key: %w[create read update delete]).index_by(&:key)

ALLOCATIONS = {
  'company_admin'     => %w[create read update delete],
  'company_manager'   => %w[create read update delete],
  'location_admin'    => %w[create read update delete],
  'location_manager'  => %w[create read update],
  'inventory_manager' => %w[create read update],
  'finance_staff'     => %w[create read update],
  'crm_specialist'    => %w[create read update],
  'sales_rep'         => %w[read],
  'company_staff'     => %w[read]
}.freeze

granted = 0
skipped = 0

Role.where(is_system_role: true, key: ALLOCATIONS.keys).find_each do |role|
  ALLOCATIONS[role.key].each do |action_key|
    action = actions[action_key]
    next unless action
    rp = RolePermission.find_or_initialize_by(
      role_id: role.id,
      resource_id: resource.id,
      action_id: action.id,
      scope_id: scope.id
    )
    if rp.new_record?
      rp.granted = true
      rp.save!
      granted += 1
      puts "  + #{role.key}: #{action_key}"
    else
      skipped += 1
    end
  end
end

puts ""
puts "Done. Granted #{granted} permissions, skipped #{skipped} (already existed)."
