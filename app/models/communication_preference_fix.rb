# Temporary fix - we'll integrate this into the main model
module CommunicationPreferenceFix
  extend ActiveSupport::Concern
  
  included do
    serialize :compliance_metadata, JSON
  end
end

CommunicationPreference.include(CommunicationPreferenceFix)
