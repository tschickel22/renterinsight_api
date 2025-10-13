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
    
    # Build context from Lead, Account, Quote, or User objects
    def build_context_from_record(record)
      case record
      when Lead
        build_lead_context(record)
      when Account
        build_account_context(record)
      when Quote
        build_quote_context(record)
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
    def build_lead_context(lead)
      {
        'lead' => object_to_hash(lead),
        'first_name' => lead.first_name,
        'last_name' => lead.last_name,
        'email' => lead.email,
        'phone' => lead.phone,
        'full_name' => "#{lead.first_name} #{lead.last_name}".strip,
        'company_name' => lead.company&.name
      }
    end
    
    # Build context for Account
    def build_account_context(account)
      {
        'account' => object_to_hash(account),
        'name' => account.name,
        'email' => account.email,
        'phone' => account.phone,
        'company_name' => account.company&.name
      }
    end
    
    # Build context for Quote
    def build_quote_context(quote)
      {
        'quote' => object_to_hash(quote),
        'quote_number' => quote.id,
        'total' => format_currency(quote.total),
        'account_name' => quote.account&.name
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
