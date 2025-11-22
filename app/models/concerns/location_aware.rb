# frozen_string_literal: true

# LocationAware concern for models that have a location_id column
# Include this in any model that should be filtered by location
#
# Usage:
#   class Vehicle < ApplicationRecord
#     include LocationAware
#   end
#
# Then in controllers, use:
#   @company.vehicles.for_current_location  # Filters by Current.location_id if set
#   Vehicle.for_location(5)                 # Explicit location filter
#
module LocationAware
  extend ActiveSupport::Concern
  
  included do
    # Scope to filter by specific location
    scope :for_location, ->(location_id) {
      if location_id.present?
        where(location_id: location_id)
      else
        all
      end
    }
    
    # Scope to filter by Current.location_id if set
    # If no location is selected, returns all records
    scope :for_current_location, -> {
      if Current.location_filtered?
        where(location_id: Current.location_id)
      else
        all
      end
    }
    
    # Scope that enforces location filtering for location-tier users
    # Admins see all, location users see only their assigned locations
    scope :location_filtered, -> {
      if Current.location_filtered?
        # Explicit location selection takes precedence
        where(location_id: Current.location_id)
      elsif Current.user&.user_locations&.active&.any?
        # Location-tier user without explicit selection - show all assigned locations
        location_ids = Current.user.user_locations.active.pluck(:location_id)
        where("#{table_name}.location_id IN (?) OR #{table_name}.location_id IS NULL", location_ids)
      else
        # Admin or no location restrictions
        all
      end
    }
  end
  
  class_methods do
    # Helper to check if model supports location filtering
    def location_aware?
      true
    end
  end
end
