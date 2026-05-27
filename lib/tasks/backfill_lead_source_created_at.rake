namespace :leads do
  desc 'Backfill source_created_at from champion_lead_data.createdDateTime. Idempotent — safe to re-run.'
  task backfill_source_created_at: :environment do
    scope = Lead.where(source_created_at: nil)
                .where.not(champion_lead_data: nil)

    total = scope.count
    puts "Found #{total} Champion leads with NULL source_created_at"

    fixed = 0
    missing = 0

    scope.find_each do |lead|
      data = lead.champion_lead_data
      created = data.is_a?(Hash) ? data['createdDateTime'] : nil

      if created.blank?
        missing += 1
        next
      end

      lead.update_columns(source_created_at: created)
      fixed += 1
    end

    puts "Backfill complete. Fixed #{fixed}, skipped #{missing} (no createdDateTime in payload)."
  end
end
