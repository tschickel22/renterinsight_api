class SeedSpecializedRoles < ActiveRecord::Migration[8.0]
  def up
    specialized_roles = [
      {
        key: 'service_tech',
        name: 'Service Technician',
        description: 'Service ticket management and field operations',
        color: '#f59e0b',
        department: 'service'
      },
      {
        key: 'sales_rep',
        name: 'Sales Representative',
        description: 'Quotes, deals, and CRM operations',
        color: '#ec4899',
        department: 'sales'
      },
      {
        key: 'finance_staff',
        name: 'Finance Staff',
        description: 'Payments, invoices, and financial operations',
        color: '#14b8a6',
        department: 'finance'
      },
      {
        key: 'crm_specialist',
        name: 'CRM Specialist',
        description: 'Lead management and customer relations',
        color: '#8b5cf6',
        department: 'crm'
      },
      {
        key: 'inventory_manager',
        name: 'Inventory Manager',
        description: 'Inventory and operations management',
        color: '#6366f1',
        department: 'operations'
      }
    ]

    specialized_roles.each do |role_attrs|
      Role.find_or_create_by!(
        company_id: nil,
        is_system_role: true,
        tier: 'location',
        key: role_attrs[:key]
      ) do |r|
        r.name = role_attrs[:name]
        r.description = role_attrs[:description]
        r.color = role_attrs[:color]
        r.department = role_attrs[:department]
        r.active = true
      end
    end

    puts "✅ Seeded #{specialized_roles.count} specialized roles"
    puts "Total system roles: #{Role.system_roles.count}"
  end

  def down
    # Remove the specialized roles if rolling back
    specialized_keys = ['service_tech', 'sales_rep', 'finance_staff', 'crm_specialist', 'inventory_manager']
    Role.where(key: specialized_keys, is_system_role: true, company_id: nil).destroy_all
    puts "Removed specialized roles"
  end
end
