namespace :invoices do
  desc 'Assign a default location to invoices that have location_id = NULL. Idempotent — safe to re-run.'
  task backfill_locations: :environment do
    total_fixed = 0
    total_skipped = 0

    Company.find_each do |company|
      null_invoices = company.invoices.where(location_id: nil)
      next if null_invoices.empty?

      fallback = company.locations.where(active: true, is_deleted: [false, nil]).order(:id).first

      unless fallback
        puts "⚠️  Company #{company.id} (#{company.name}) has #{null_invoices.count} NULL-location invoices but NO active location to assign — skipping"
        total_skipped += null_invoices.count
        next
      end

      count = null_invoices.count
      null_invoices.update_all(location_id: fallback.id, updated_at: Time.current)
      puts "✅ Company #{company.id} (#{company.name}): assigned #{count} invoices to #{fallback.name} (id=#{fallback.id})"
      total_fixed += count
    end

    puts ""
    puts "Backfill complete. Fixed #{total_fixed} invoices, skipped #{total_skipped}."
  end
end
