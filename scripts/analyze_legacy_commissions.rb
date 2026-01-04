#!/usr/bin/env ruby
# frozen_string_literal: true

# Analysis script for legacy commission system
# Run with: bin/rails runner scripts/analyze_legacy_commissions.rb

puts "🔍 ANALYZING LEGACY COMMISSION SYSTEM"
puts "=" * 80

# Check if legacy tables exist
puts "\n📊 LEGACY TABLES:"

legacy_tables = {
  'commissions' => Commission,
  'commission_rules' => CommissionRule,
  'commission_audit_entries' => CommissionAuditEntry
}

legacy_tables.each do |table_name, model_class|
  if ActiveRecord::Base.connection.table_exists?(table_name)
    puts "\n✅ Table: #{table_name}"
    puts "   Columns: #{model_class.column_names.join(', ')}"
    puts "   Record count: #{model_class.count}"
    
    if model_class.count > 0
      puts "   Sample IDs: #{model_class.limit(5).pluck(:id).join(', ')}"
    end
  else
    puts "\n❌ Table NOT found: #{table_name}"
  end
rescue StandardError => e
  puts "\n⚠️  Error checking #{table_name}: #{e.message}"
end

# Check new tables
puts "\n\n📊 NEW TABLES (Phase 0):"

new_tables = {
  'commission_components' => CommissionComponent,
  'commission_payments' => CommissionPayment
}

new_tables.each do |table_name, model_class|
  if ActiveRecord::Base.connection.table_exists?(table_name)
    puts "\n✅ Table: #{table_name}"
    puts "   Columns: #{model_class.column_names.join(', ')}"
    puts "   Record count: #{model_class.count}"
  else
    puts "\n❌ Table NOT found: #{table_name}"
  end
rescue StandardError => e
  puts "\n⚠️  Error checking #{table_name}: #{e.message}"
end

# Compare systems
puts "\n\n🔄 SYSTEM COMPARISON:"
puts "-" * 80

puts "\nLEGACY SYSTEM:"
puts "  • Commission model: flat, percentage, tiered"
puts "  • CommissionRule: defines calculation rules"
puts "  • Status workflow: pending → approved → paid"
puts "  • Audit tracking via CommissionAuditEntry"

puts "\nNEW SYSTEM (Phase 0):"
puts "  • CommissionComponent: 4 types (percent_of_gross, flat_per_unit, monthly_bonus, addon)"
puts "  • CommissionPayment: workflow with auto-generation"
puts "  • Status workflow: pending → approved → paid → reversed"
puts "  • Calculation details stored in JSONB"

# Check if there's production data
puts "\n\n⚠️  MIGRATION CONSIDERATIONS:"
puts "-" * 80

if defined?(Commission) && Commission.count > 0
  puts "\n🚨 LEGACY DATA EXISTS!"
  puts "   Total commissions: #{Commission.count}"
  puts "   Statuses: #{Commission.group(:status).count}"
  
  if Commission.where(status: ['pending', 'approved']).any?
    puts "\n   ⚠️  WARNING: Active commissions exist!"
    puts "   Pending: #{Commission.pending.count}"
    puts "   Approved: #{Commission.approved.count}"
  end
  
  puts "\n   📋 MIGRATION NEEDS:"
  puts "   1. Map CommissionRule → CommissionComponent"
  puts "   2. Map Commission → CommissionPayment"
  puts "   3. Preserve audit trail"
  puts "   4. Handle in-flight approvals"
else
  puts "\n✅ No legacy data - clean migration"
end

puts "\n\n" + "=" * 80
puts "Analysis complete!"
