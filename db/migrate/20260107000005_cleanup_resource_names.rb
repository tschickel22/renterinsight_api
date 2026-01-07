class CleanupResourceNames < ActiveRecord::Migration[8.0]
  def up
    # Map of resource keys to properly formatted names
    resource_name_updates = {
      'commission_components' => 'Commission Components',
      'commission_payments' => 'Commission Payments',
      'commissions' => 'Commissions',
      'communications' => 'Communications',
      'crm_contacts' => 'CRM & Contacts',
      'deals' => 'Deals & Opportunities',
      'deals_cost_details' => 'Deals (Cost Details)',
      'finance_billing' => 'Finance & Billing',
      'inventory' => 'Inventory',
      'inventory_cost_details' => 'Inventory (Cost Details)',
      'leads' => 'Leads',
      'loans' => 'Loans',
      'manufacturer_ar' => 'Manufacturer AR',
      'manufacturers' => 'Manufacturers',
      'products' => 'Products',
      'calendar' => 'Calendar',
      'service_tickets' => 'Service Tickets',
      'warranties' => 'Warranties',
      'brochures' => 'Brochures',
      'intake_forms' => 'Intake Forms',
      'company_settings' => 'Company Settings',
      'location_settings' => 'Location Settings',
      'user_management' => 'User Management',
      'role_management' => 'Role Management',
      'regions' => 'Regions',
      'reporting' => 'Reporting',
      'email_templates' => 'Email Templates',
      'sms_templates' => 'SMS Templates',
      'custom_fields' => 'Custom Fields',
      'pipelines' => 'Pipelines',
      'integrations' => 'Integrations'
    }
    
    # Update each resource name
    resource_name_updates.each do |key, new_name|
      resource = Resource.find_by(key: key)
      if resource
        old_name = resource.name
        resource.update!(name: new_name)
        puts "✅ Updated: '#{old_name}' → '#{new_name}'"
      else
        puts "⚠️  Resource not found: #{key}"
      end
    end
    
    puts "✅ Resource names cleaned up successfully"
  end

  def down
    # Revert to original names with underscores (best effort)
    reversions = {
      'Commission Components' => 'Commission_components',
      'Commission Payments' => 'Commission_payments',
      'CRM & Contacts' => 'CRM_contacts',
      'Deals & Opportunities' => 'Deals',
      'Deals (Cost Details)' => 'Deals_cost_details',
      'Finance & Billing' => 'Finance_billing',
      'Inventory (Cost Details)' => 'Inventory_cost_details',
      'Manufacturer AR' => 'Manufacturer_ar',
      'Service Tickets' => 'Service_tickets',
      'Intake Forms' => 'Intake_forms',
      'Company Settings' => 'Company_settings',
      'Location Settings' => 'Location_settings',
      'User Management' => 'User_management',
      'Role Management' => 'Role_management',
      'Email Templates' => 'Email_templates',
      'SMS Templates' => 'SMS_templates',
      'Custom Fields' => 'Custom_fields'
    }
    
    reversions.each do |new_name, old_name|
      Resource.where(name: new_name).update_all(name: old_name)
    end
    
    puts "⚠️  Reverted resource names to original format"
  end
end
