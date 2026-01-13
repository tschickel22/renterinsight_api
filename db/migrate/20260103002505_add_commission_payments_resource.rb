# frozen_string_literal: true

class AddCommissionPaymentsResource < ActiveRecord::Migration[8.0]
  def up
    # Reload Resource model to pick up permission_ui_type column from previous migration
    Resource.reset_column_information
    
    # Add commission_payments resource if it doesn't exist
    unless Resource.exists?(key: 'commission_payments')
      Resource.create!(
        key: 'commission_payments',
        name: 'Commission Payments',
        description: 'View and manage commission payment records, approvals, and disbursements',
        category: 'operations',
        active: true,
        permission_ui_type: 'custom'  # Custom because we have approve, mark_paid, reverse actions
      )
      
      Rails.logger.info "✅ Created 'commission_payments' RBAC resource"
    end
  end
  
  def down
    Resource.find_by(key: 'commission_payments')&.destroy
  end
end
