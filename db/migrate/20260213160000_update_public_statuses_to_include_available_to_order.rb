class UpdatePublicStatusesToIncludeAvailableToOrder < ActiveRecord::Migration[8.0]
  def up
    # Update all existing companies to include 'available_to_order' in their public_statuses
    Company.find_each do |company|
      # Get current public_statuses
      current_statuses = if company.public_statuses.is_a?(String)
        begin
          JSON.parse(company.public_statuses)
        rescue JSON::ParserError
          [company.public_statuses]
        end
      elsif company.public_statuses.is_a?(Array)
        company.public_statuses
      else
        ['available']
      end
      
      # Add 'available_to_order' if not already present
      unless current_statuses.include?('available_to_order')
        current_statuses << 'available_to_order'
        company.update_column(:public_inventory_settings, 
          company.public_inventory_settings.merge('public_statuses' => current_statuses))
      end
    end
  end

  def down
    # Remove 'available_to_order' from all companies
    Company.find_each do |company|
      current_statuses = if company.public_statuses.is_a?(String)
        begin
          JSON.parse(company.public_statuses)
        rescue JSON::ParserError
          [company.public_statuses]
        end
      elsif company.public_statuses.is_a?(Array)
        company.public_statuses
      else
        ['available']
      end
      
      current_statuses.delete('available_to_order')
      company.update_column(:public_inventory_settings, 
        company.public_inventory_settings.merge('public_statuses' => current_statuses))
    end
  end
end
