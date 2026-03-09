# Run this after migrating to create master records for existing groups:
#   bin/rails runner lib/tasks/backfill_master_templates.rb

puts "Backfilling master templates for existing groups..."

groups = AgreementTemplate.where(is_platform_template: true, is_deleted: false)
                          .where.not(template_group_id: nil)
                          .group(:template_group_id)
                          .pluck(:template_group_id)

created = 0
skipped = 0

groups.each do |group_id|
  # Skip if master already exists
  if AgreementTemplate.exists?(template_group_id: group_id, is_master: true, is_deleted: false)
    skipped += 1
    next
  end

  # Find first state template to copy from
  source = AgreementTemplate.where(template_group_id: group_id, is_deleted: false)
                             .order(:state_code)
                             .first

  next unless source

  # Create master from source
  master = source.dup
  master.name = source.name.gsub(/ - [A-Z]{2}$/, '')
  master.state_code = nil
  master.is_master = true
  master.save!

  created += 1
  puts "  Created master ##{master.id} for group #{group_id}: #{master.name}"
end

puts "Done! Created #{created} master(s), skipped #{skipped} (already had master)"
