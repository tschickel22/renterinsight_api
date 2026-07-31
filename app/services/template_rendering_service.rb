# frozen_string_literal: true

require 'liquid'

class TemplateRenderingService
  class << self
    # Render a template string with the provided context
    # Supports Liquid syntax: {{ variable }} and {{ object.attribute }}
    def render(template_string, context = {})
      return template_string if template_string.blank?
      
      # Prepare context with safe access to object attributes
      safe_context = prepare_context(context)
      
      # Parse and render using Liquid
      template = Liquid::Template.parse(template_string)
      template.render(safe_context, strict_variables: false, strict_filters: false)
    rescue Liquid::SyntaxError => e
      Rails.logger.error("Template rendering syntax error: #{e.message}")
      template_string # Return original on error
    rescue => e
      Rails.logger.error("Template rendering error: #{e.message}")
      template_string # Return original on error
    end
    
    # Build context from Lead, Account, Contact, Quote, or User objects
    # @param record [ActiveRecord::Base] The record to build context from
    # @param sending_user [User] Optional user who is sending the communication (for rep fields)
    def build_context_from_record(record, sending_user: nil)
      case record
      when Lead
        build_lead_context(record, sending_user: sending_user)
      when Contact
        build_contact_context(record, sending_user: sending_user)
      when Account
        build_account_context(record, sending_user: sending_user)
      when Quote
        build_quote_context(record, sending_user: sending_user)
      when User
        build_user_context(record)
      else
        {}
      end
    end
    
    private
    
    # Prepare context hash with safe attribute access
    def prepare_context(context)
      safe_context = {}
      
      context.each do |key, value|
        case value
        when ActiveRecord::Base
          # Convert AR objects to hash representation
          safe_context[key.to_s] = object_to_hash(value)
        when Hash
          # Recursively prepare nested hashes
          safe_context[key.to_s] = prepare_context(value)
        else
          # Use value directly
          safe_context[key.to_s] = value
        end
      end
      
      safe_context
    end
    
    # Convert ActiveRecord object to hash with safe attribute access
    def object_to_hash(record)
      return {} unless record
      
      hash = {}
      
      # Get all attribute names
      record.attributes.each do |key, value|
        hash[key] = format_value(value)
      end
      
      # Add computed/virtual attributes
      add_computed_attributes(hash, record)
      
      hash
    end
    
    # Format values for template rendering
    def format_value(value)
      case value
      when Date, DateTime, Time
        value.to_s
      when BigDecimal
        value.to_f
      else
        value
      end
    end
    
    # Add computed attributes based on record type
    def add_computed_attributes(hash, record)
      case record
      when Lead
        hash['full_name'] = "#{record.first_name} #{record.last_name}".strip
        hash['display_name'] = record.first_name.presence || record.email
      when Account
        hash['full_name'] = record.name
        hash['display_name'] = record.name
      when Quote
        hash['total_formatted'] = format_currency(record.total)
      end
    end
    
    # Build context for Lead
    def build_lead_context(lead, sending_user: nil)
      # Get the owner/assigned user for rep fields
      # Priority: sending_user (person clicking send) > lead.owner > first active user
      rep_user = sending_user || lead.owner || lead.company&.users&.active&.first
      
      # Get location for company_name (Location Name with Company fallback)
      location = lead.location || rep_user&.location
      company = lead.company
      
      {
        'lead' => object_to_hash(lead),
        'first_name' => lead.first_name,
        'last_name' => lead.last_name,
        'email' => lead.email,
        'phone' => lead.phone,
        'full_name' => "#{lead.first_name} #{lead.last_name}".strip,
        
        # 🔧 FIX: Company name uses Location name with Company fallback
        'company_name' => location&.name || company&.name || '',
        'location_name' => location&.name || '',
        
        # 🔧 FIX: Rep fields from User account settings
        'rep_name' => rep_user ? "#{rep_user.first_name} #{rep_user.last_name}".strip : '',
        'rep_email' => rep_user&.email || '',
        'rep_phone' => rep_user&.phone || '',
        
        # 🔧 FIX: Website URL from Company Settings > Domain
        'website_url' => company&.domain || ''
      }
    end
    
    # Build context for Account
    def build_account_context(account, sending_user: nil)
      # Get the owner/assigned user for rep fields
      # Priority: sending_user (person clicking send) > account.owner > first active user
      rep_user = sending_user || account.owner || account.company&.users&.active&.first
      
      # Get location for company_name (Location Name with Company fallback)
      location = account.location || rep_user&.location
      company = account.company
      
      {
        'account' => object_to_hash(account),
        'name' => account.name,
        'email' => account.email,
        'phone' => account.phone,
        
        # 🔧 FIX: Company name uses Location name with Company fallback
        'company_name' => location&.name || company&.name || '',
        'location_name' => location&.name || '',
        
        # 🔧 FIX: Rep fields from User account settings
        'rep_name' => rep_user ? "#{rep_user.first_name} #{rep_user.last_name}".strip : '',
        'rep_email' => rep_user&.email || '',
        'rep_phone' => rep_user&.phone || '',
        
        # 🔧 FIX: Website URL from Company Settings > Domain
        'website_url' => company&.domain || ''
      }
    end
    
    # Build context for Contact
    def build_contact_context(contact, sending_user: nil)
      # Get the owner/assigned user for rep fields
      # Priority: sending_user (person clicking send) > contact.owner > first active user
      rep_user = sending_user || contact.owner || contact.company&.users&.active&.first
      
      # Get location for company_name (Location Name with Company fallback)
      location = contact.location || rep_user&.location
      company = contact.company
      
      {
        'contact' => object_to_hash(contact),
        'first_name' => contact.first_name,
        'last_name' => contact.last_name,
        'email' => contact.email,
        'phone' => contact.phone,
        'full_name' => "#{contact.first_name} #{contact.last_name}".strip,
        
        # 🔧 FIX: Company name uses Location name with Company fallback
        'company_name' => location&.name || company&.name || '',
        'location_name' => location&.name || '',
        
        # 🔧 FIX: Rep fields from User account settings
        'rep_name' => rep_user ? "#{rep_user.first_name} #{rep_user.last_name}".strip : '',
        'rep_email' => rep_user&.email || '',
        'rep_phone' => rep_user&.phone || '',
        
        # 🔧 FIX: Website URL from Company Settings > Domain
        'website_url' => company&.domain || ''
      }
    end
    
    # Build context for Quote
    def build_quote_context(quote, sending_user: nil)
      # Get rep user from sending_user or the quote's sales rep. Quote has no
      # `owner` association (unlike Lead/Account/Contact) — sales_rep is its equivalent.
      rep_user = sending_user || quote.sales_rep || quote.company&.users&.active&.first
      location = quote.location || rep_user&.location
      company = quote.company
      
      {
        'quote' => object_to_hash(quote),
        'quote_number' => quote.id,
        'total' => format_currency(quote.total),
        'account_name' => quote.account&.name,
        
        # Add rep fields for quotes too
        'company_name' => location&.name || company&.name || '',
        'location_name' => location&.name || '',
        'rep_name' => rep_user ? "#{rep_user.first_name} #{rep_user.last_name}".strip : '',
        'rep_email' => rep_user&.email || '',
        'rep_phone' => rep_user&.phone || '',
        'website_url' => company&.domain || ''
      }
    end
    
    # Build context for User
    def build_user_context(user)
      {
        'user' => object_to_hash(user),
        'user_name' => user.name,
        'user_email' => user.email
      }
    end
    
    # Format currency
    def format_currency(amount)
      return '$0.00' unless amount
      "$#{'%.2f' % amount}"
    end
  end
end
