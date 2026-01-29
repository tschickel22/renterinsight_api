#!/usr/bin/env ruby
# Lead Import Script - Kyle's Champion Homes Data
# Usage: bin/rails runner scripts/import_leads.rb <company_id> <excel_file> <mode> [options]
# Example: bin/rails runner scripts/import_leads.rb 47 tmp/Kyle_Lead_Upload.xlsx dry_run
# Example: bin/rails runner scripts/import_leads.rb 47 tmp/Kyle_Lead_Upload.xlsx execute owner_email=kyle@example.com

require 'roo'

class LeadImporter
  attr_reader :company_id, :dry_run, :stats, :excel_path
  
  def initialize(company_id, excel_path, dry_run: true, options: {})
    @company_id = company_id
    @excel_path = excel_path
    @dry_run = dry_run
    @options = options
    @stats = {
      total: 0,
      created: 0,
      skipped: 0,
      errors: 0,
      error_details: []
    }
    
    # Validate company exists
    @company = Company.find_by(id: company_id)
    raise "Company #{company_id} not found!" unless @company
    
    # Validate Excel file exists
    raise "Excel file '#{excel_path}' not found!" unless File.exist?(excel_path)
    
    puts "=" * 80
    puts "LEAD IMPORT - #{@dry_run ? 'DRY RUN' : 'LIVE EXECUTION'}"
    puts "=" * 80
    puts "Company: #{@company.name} (ID: #{@company.id})"
    puts "Mode: #{@dry_run ? '🔍 DRY RUN (no changes)' : '⚠️  LIVE (will create records)'}"
    puts "Excel File: #{@excel_path}"
    puts "Options: #{@options.inspect}"
    puts "=" * 80
    puts ""
  end
  
  def import!
    xlsx = Roo::Spreadsheet.open(@excel_path)
    sheet = xlsx.sheet(0)
    
    headers = sheet.row(1)
    puts "📋 Excel Headers: #{headers.join(', ')}\n\n"
    
    # Find default owner if provided
    default_owner = nil
    if @options[:owner_email].present?
      default_owner = @company.users.find_by(email: @options[:owner_email])
      if default_owner
        puts "✅ Default Owner: #{default_owner.full_name} (#{default_owner.email})"
      else
        puts "⚠️  Owner email '#{@options[:owner_email]}' not found in company"
      end
    end
    
    # Find or create default source
    default_source = find_or_create_default_source
    puts "✅ Default Source: #{default_source.name} (ID: #{default_source.id})\n\n"
    
    # Start transaction if not dry run
    ActiveRecord::Base.transaction do
      (2..sheet.last_row).each do |row_num|
        @stats[:total] += 1
        
        row_data = {
          first_name: clean_string(sheet.cell(row_num, 1)),
          last_name: clean_string(sheet.cell(row_num, 2)),
          email: clean_email(sheet.cell(row_num, 3)),
          phone: clean_phone(sheet.cell(row_num, 4)),
          lead_source_name: clean_string(sheet.cell(row_num, 5)),
          description: clean_string(sheet.cell(row_num, 6))
        }
        
        process_row(row_num, row_data, default_owner, default_source)
        
        # Progress indicator every 100 rows
        if @stats[:total] % 100 == 0
          puts "📊 Progress: #{@stats[:total]} rows processed..."
        end
      end
      
      # Rollback if dry run
      raise ActiveRecord::Rollback if @dry_run
    end
    
    print_summary
  end
  
  private
  
  def process_row(row_num, data, default_owner, default_source)
    # Validation: Must have first_name OR last_name
    if data[:first_name].blank? && data[:last_name].blank?
      record_error(row_num, "Missing both first and last name")
      return
    end
    
    # Validation: Must have email
    if data[:email].blank?
      record_error(row_num, "Missing email")
      return
    end
    
    # Check for duplicate email in this company
    existing = @company.leads.find_by(email: data[:email])
    if existing
      @stats[:skipped] += 1
      puts "⏭️  Row #{row_num}: SKIPPED - Email already exists (Lead ID: #{existing.id})" if @dry_run
      return
    end
    
    # Lookup source
    source = lookup_source(data[:lead_source_name]) || default_source
    
    # Build lead
    lead = @company.leads.new(
      first_name: data[:first_name],
      last_name: data[:last_name],
      email: data[:email],
      phone: data[:phone],
      notes: data[:description], # ✅ Description → notes
      source_id: source.id,
      owner_id: default_owner&.id,
      status: @options[:default_status] || 'new',
      location_id: @options[:location_id]
    )
    
    if @dry_run
      # Validate but don't save
      if lead.valid?
        @stats[:created] += 1
        puts "✅ Row #{row_num}: VALID - #{lead.first_name} #{lead.last_name} (#{lead.email})"
      else
        record_error(row_num, lead.errors.full_messages.join(', '))
      end
    else
      # Save for real
      if lead.save
        @stats[:created] += 1
        puts "✅ Row #{row_num}: CREATED - Lead ID: #{lead.id} (#{lead.email})"
      else
        record_error(row_num, lead.errors.full_messages.join(', '))
      end
    end
    
  rescue => e
    record_error(row_num, "Exception: #{e.message}")
  end
  
  def lookup_source(source_name)
    return nil if source_name.blank?
    
    # Try exact match first
    source = @company.sources.find_by(name: source_name)
    return source if source
    
    # Try case-insensitive match
    source = @company.sources.where('LOWER(name) = ?', source_name.downcase).first
    return source if source
    
    # Create source if not found
    puts "   ℹ️  Creating new source: #{source_name}"
    @company.sources.create!(name: source_name)
  end
  
  def find_or_create_default_source
    # Try to find existing "Website" or "Import" source
    source = @company.sources.find_by(name: 'Import') ||
             @company.sources.find_by(name: 'Website') ||
             @company.sources.first
    
    # Create default if none exist
    if source.nil?
      source = @company.sources.create!(
        name: 'Import',
      )
    end
    
    source
  end
  
  def clean_string(value)
    return nil if value.nil?
    value.to_s.strip.presence
  end
  
  def clean_email(value)
    return nil if value.nil?
    email = value.to_s.strip.downcase
    email.presence
  end
  
  def clean_phone(value)
    return nil if value.nil?
    # Remove all non-numeric characters except leading +
    phone = value.to_s.gsub(/[^\d+]/, '')
    phone.presence
  end
  
  def record_error(row_num, message)
    @stats[:errors] += 1
    @stats[:error_details] << "Row #{row_num}: #{message}"
    puts "❌ Row #{row_num}: ERROR - #{message}"
  end
  
  def print_summary
    puts "\n"
    puts "=" * 80
    puts "IMPORT SUMMARY"
    puts "=" * 80
    puts "Total Rows:     #{@stats[:total]}"
    puts "Created:        #{@stats[:created]} ✅"
    puts "Skipped (dups): #{@stats[:skipped]} ⏭️"
    puts "Errors:         #{@stats[:errors]} ❌"
    puts "=" * 80
    
    if @stats[:errors] > 0 && @stats[:error_details].count <= 20
      puts "\nERROR DETAILS:"
      puts "-" * 80
      @stats[:error_details].each { |err| puts err }
    elsif @stats[:errors] > 20
      puts "\n⚠️  #{@stats[:errors]} errors occurred. First 20:"
      puts "-" * 80
      @stats[:error_details].first(20).each { |err| puts err }
    end
    
    puts "\n"
    if @dry_run
      puts "🔍 DRY RUN COMPLETE - No records were created"
      puts "To execute for real, run with 'execute' instead of 'dry_run'"
    else
      puts "✅ IMPORT COMPLETE - #{@stats[:created]} leads created!"
    end
    puts "=" * 80
  end
end

# ========================================
# SCRIPT EXECUTION
# ========================================

if ARGV.length < 3
  puts "Usage: bin/rails runner scripts/import_leads.rb <company_id> <excel_file> <dry_run|execute> [options]"
  puts ""
  puts "Examples:"
  puts "  bin/rails runner scripts/import_leads.rb 47 tmp/Kyle_Lead_Upload.xlsx dry_run"
  puts "  bin/rails runner scripts/import_leads.rb 47 tmp/Kyle_Lead_Upload.xlsx execute"
  puts "  bin/rails runner scripts/import_leads.rb 47 tmp/Kyle_Lead_Upload.xlsx execute owner_email=kyle@example.com"
  puts ""
  exit 1
end

company_id = ARGV[0].to_i
excel_path = ARGV[1]
mode = ARGV[2]
dry_run = (mode != 'execute')

# Parse options
options = {}
ARGV[3..-1].each do |arg|
  key, value = arg.split('=')
  options[key.to_sym] = value
end

importer = LeadImporter.new(company_id, excel_path, dry_run: dry_run, options: options)
importer.import!
