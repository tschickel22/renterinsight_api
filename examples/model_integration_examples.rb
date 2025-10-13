# Example of how to update existing models to use the unified communication system
# These are templates - actual implementation will depend on your existing model structure

# ============================================================================
# app/models/lead.rb
# ============================================================================
class Lead < ApplicationRecord
  include Communicable
  
  # Existing associations and validations...
  
  # Implement required methods for Communicable concern
  def primary_email
    email
  end
  
  def primary_phone
    phone
  end
  
  # Example: Override send_quote_email to use unified system
  def send_quote_email(quote, to: nil)
    CommunicationService.send_quote_email(
      quote: quote,
      to: to || primary_email,
      from: ENV['QUOTE_FROM_EMAIL'],
      category: 'quotes'
    )
  end
end

# ============================================================================
# app/models/account.rb
# ============================================================================
class Account < ApplicationRecord
  include Communicable
  
  # Existing associations and validations...
  has_many :contacts
  
  # Implement required methods for Communicable concern
  def primary_email
    primary_contact&.email || contacts.first&.email
  end
  
  def primary_phone
    primary_contact&.phone || contacts.first&.phone
  end
  
  def primary_contact
    contacts.find_by(is_primary: true)
  end
end

# ============================================================================
# app/models/quote.rb
# ============================================================================
class Quote < ApplicationRecord
  include Communicable
  
  belongs_to :lead, optional: true
  belongs_to :account, optional: true
  
  # Existing associations and validations...
  
  # Implement required methods for Communicable concern
  def primary_email
    lead&.email || account&.primary_email
  end
  
  def primary_phone
    lead&.phone || account&.primary_phone
  end
  
  # Keep existing send_email method but use unified system internally
  def send_email(to: nil, **options)
    CommunicationService.send_quote_email(
      quote: self,
      to: to || primary_email,
      category: 'quotes',
      **options
    )
  end
  
  # Get all communications related to this quote
  def all_communications
    Communication.where(
      "(communicable_type = 'Quote' AND communicable_id = :id) OR " \
      "(metadata->>'quote_id' = :quote_id)",
      id: id,
      quote_id: id.to_s
    ).order(created_at: :desc)
  end
end

# ============================================================================
# app/models/user.rb (if you want users to have communication preferences)
# ============================================================================
class User < ApplicationRecord
  include Communicable
  
  # Existing associations and validations...
  
  def primary_email
    email
  end
  
  def primary_phone
    phone
  end
end

# ============================================================================
# MIGRATION: Add polymorphic associations to existing tables (OPTIONAL)
# ============================================================================
# Only needed if you want to add direct foreign key support
# The polymorphic association works without these migrations

# class AddCommunicationAssociations < ActiveRecord::Migration[7.0]
#   def change
#     # Optional: Add indexes to improve query performance
#     # These are redundant with the polymorphic index but can help specific queries
#     
#     # For leads
#     add_index :communications, [:communicable_id], 
#               where: "communicable_type = 'Lead'",
#               name: 'idx_communications_on_lead_id'
#     
#     # For accounts
#     add_index :communications, [:communicable_id], 
#               where: "communicable_type = 'Account'",
#               name: 'idx_communications_on_account_id'
#     
#     # For quotes
#     add_index :communications, [:communicable_id], 
#               where: "communicable_type = 'Quote'",
#               name: 'idx_communications_on_quote_id'
#   end
# end
