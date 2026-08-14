# frozen_string_literal: true

# Gives every company a contact form, so an inventory ad has somewhere to land.
#
# A Meta catalog item must carry a link. Without a form there is no destination,
# so the feed sends no link, Meta rejects the item, and the dealer's entire feed
# is empty for a reason nothing on screen explains. New companies now get one at
# creation; this is for the ones that already exist.
#
# Reuses Websites::DefaultLeadForm.ensure_for, which returns an existing
# general-purpose form rather than making a second one, so this is safe to run
# repeatedly.
#
#   bin/rails intake:backfill_default_forms           # dry run
#   bin/rails intake:backfill_default_forms APPLY=1   # create them
namespace :intake do
  desc 'Create a contact form for every company that has none (APPLY=1 to write)'
  task backfill_default_forms: :environment do
    apply = ENV['APPLY'].present?

    without_form = Company.where.not(
      id: IntakeForm.select(:company_id).distinct
    ).order(:id)

    if without_form.empty?
      puts 'every company already has at least one intake form'
      next
    end

    puts "#{without_form.count} companies have no intake form"

    created = 0
    skipped = 0

    without_form.find_each do |company|
      label = "#{company.id} #{company.name}"

      unless apply
        puts "  would create a contact form for #{label}"
        next
      end

      form = Websites::DefaultLeadForm.ensure_for(company)

      if form
        created += 1
        puts "  #{label}: created form ##{form.id} (public_id #{form.public_id})"
      else
        skipped += 1
        puts "  #{label}: could not create a form, left alone"
      end
    end

    if apply
      puts "created=#{created} failed=#{skipped}"
    else
      puts 'MODE: dry run (pass APPLY=1 to write)'
    end
  end
end
