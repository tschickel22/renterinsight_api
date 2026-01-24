class SetDefaultAppliesToRole < ActiveRecord::Migration[8.0]
  def up
    # Find all components without applies_to_role and set intelligent defaults
    CommissionComponent.where(applies_to_role: nil).find_each do |component|
      role = guess_role_from_component(component)
      
      puts "Setting component '#{component.name}' (ID: #{component.id}) to role: #{role}"
      component.update_column(:applies_to_role, role)
    end
    
    # Now add NOT NULL constraint
    change_column_null :commission_components, :applies_to_role, false
  end
  
  def down
    change_column_null :commission_components, :applies_to_role, true
  end
  
  private
  
  def guess_role_from_component(component)
    name_lower = component.name.downcase
    
    # Check for keywords in component name
    return 'finance_manager' if name_lower.match?(/finance|f&i|f & i|reserve|warranty|product/)
    return 'sales_manager' if name_lower.match?(/manager|override|supervisor/)
    return 'desk_manager' if name_lower.match?(/desk/)
    return 'secondary_salesperson' if name_lower.match?(/split|secondary|second/)
    
    # Default to primary salesperson for everything else (most common case)
    'primary_salesperson'
  end
end
