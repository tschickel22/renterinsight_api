# frozen_string_literal: true

class MakeAppliesToRoleRequiredOnCommissionComponents < ActiveRecord::Migration[8.0]
  def up
    # Set default value for existing records that don't have applies_to_role set
    # Use 'primary_salesperson' as the default since that's the most common case
    CommissionComponent.where(applies_to_role: nil).update_all(applies_to_role: 'primary_salesperson')
    
    # Now make the column non-nullable
    change_column_null :commission_components, :applies_to_role, false
  end
  
  def down
    # Allow null again if we need to rollback
    change_column_null :commission_components, :applies_to_role, true
  end
end
