# frozen_string_literal: true

# Current is a thread-safe store for request-specific attributes
# Use this to pass context (like current user, company, location) to models
# without passing them explicitly through every method call
#
# Set values in ApplicationController:
#   Current.user = current_user
#   Current.company_id = current_company_id
#   Current.location_id = current_location_id
#
# Read values anywhere (controllers, models, services):
#   Current.location_id
#   Current.location_filtered? 
#
class Current < ActiveSupport::CurrentAttributes
  attribute :user, :original_user, :company_id, :location_id, :ip_address
  
  # Check if we're filtering by a specific location
  def location_filtered?
    location_id.present?
  end
  
  # Get the current location object
  def location
    @location ||= location_id ? Location.find_by(id: location_id) : nil
  end
  
  # Get the current company object  
  def company
    @company ||= company_id ? Company.find_by(id: company_id) : nil
  end
  
  # Reset cached objects when attributes change
  def reset
    @location = nil
    @company = nil
    super
  end
end
