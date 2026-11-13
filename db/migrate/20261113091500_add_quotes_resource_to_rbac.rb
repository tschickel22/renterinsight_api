# frozen_string_literal: true

# Quotes move off the 'finance' permission onto their own 'quotes' resource, so a
# sales rep can quote a deal without being handed payments and invoices.
#
# No 'quotes' row existed before this, so the quotes grant in
# grant_sales_rep_permissions! did nothing and every quote screen answered to
# 'finance'. To make sure nobody loses access:
#
# 1. Every role (system and custom, every company) gets on 'quotes' exactly the
#    actions and scopes it holds on 'finance' today.
# 2. Sales rep roles also get full quote access (create, read, update, delete,
#    export), as their seed always intended.
#
# Additive only. Finance grants are left as they are. Safe to run while the old
# code is live: the old code never reads the 'quotes' row.
class AddQuotesResourceToRbac < ActiveRecord::Migration[8.0]
  def up
    resource = Resource.find_or_create_by!(key: 'quotes') do |r|
      r.name = 'Quotes'
      r.description = 'Create, send and manage customer quotes'
      r.category = 'operations'
      r.active = true
      r.position = 113
    end

    finance = Resource.find_by(key: 'finance')
    if finance
      execute <<~SQL.squish
        INSERT INTO role_permissions (role_id, resource_id, action_id, scope_id, granted, created_at, updated_at)
        SELECT role_id, #{resource.id}, action_id, scope_id, TRUE, NOW(), NOW()
        FROM role_permissions
        WHERE resource_id = #{finance.id} AND granted = TRUE
        ON CONFLICT (role_id, resource_id, action_id, scope_id) DO NOTHING
      SQL
    end

    all_scope = Scope.find_by(key: 'all')
    actions = Action.where(key: %w[create read update delete export])
    if all_scope
      Role.where(key: 'sales_rep').find_each do |role|
        actions.each do |action|
          RolePermission.find_or_create_by!(role: role, resource: resource, action: action, scope: all_scope) do |rp|
            rp.granted = true
          end
        end
      end
    end

    Role.clear_permission_caches!
  end

  def down
    resource = Resource.find_by(key: 'quotes')
    return unless resource

    RolePermission.where(resource: resource).delete_all
    resource.destroy
    Role.clear_permission_caches!
  end
end
