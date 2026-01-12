# frozen_string_literal: true

namespace :demo do
  desc "Seed Summit Park MH Dealership demo data for trade show (Phase 1: Core Data)"
  task mh_dealership: :environment do
    load Rails.root.join('db', 'seeds', 'mh_trade_show_demo.rb')
  end
  
  desc "Seed advanced demo data (Phase 2: Finance, Quotes, Tasks, etc.)"
  task mh_advanced: :environment do
    load Rails.root.join('db', 'seeds', 'mh_trade_show_phase2.rb')
  end
  
  desc "Seed complete demo data (Phase 1 + Phase 2)"
  task mh_complete: :environment do
    Rake::Task['demo:reset_mh'].invoke
    Rake::Task['demo:mh_advanced'].invoke
  end
  
  desc "Reset demo company data (clear and re-seed Phase 1 only)"
  task reset_mh: :environment do
    puts "🗑️  Clearing existing demo data..."
    
    company = Company.find_by(name: 'Summit Park Manufactured Homes')
    if company
      puts "   Deleting company and all related records..."
      # Delete in correct order to avoid foreign key violations
      # Phase 2 entities first
      company.tasks.delete_all
      Note.where(entity_type: ['Contact', 'Deal', 'Account']).delete_all
      company.commissions.delete_all
      company.warranty_claims.delete_all
      company.payments.delete_all
      InvoiceItem.where(invoice_id: company.invoices.pluck(:id)).delete_all  # Delete items BEFORE invoices
      company.invoices.delete_all
      company.loans.delete_all
      company.payment_methods.delete_all
      company.quotes.delete_all
      company.listings.delete_all
      company.brochures.delete_all
      company.accounts.delete_all
      company.tags.delete_all
      
      # Phase 1 entities
      company.service_tickets.delete_all
      company.deals.delete_all
      company.contacts.delete_all
      company.leads.delete_all
      company.vehicles.delete_all
      company.users.delete_all
      company.locations.delete_all
      company.destroy!
      puts "   ✅ Cleared"
    else
      puts "   No existing demo company found"
    end
    
    puts ""
    puts "🌱 Re-seeding demo data..."
    load Rails.root.join('db', 'seeds', 'mh_trade_show_demo.rb')
  end
end
