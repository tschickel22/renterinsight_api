# frozen_string_literal: true

# Gives every company a contact form a shopper can actually be reached through.
#
# Two problems, one fix. A company with no form at all gives a catalog item no
# link, so Meta rejects every home and the feed is empty for a reason nothing on
# screen explains. A company whose only general form collects neither an email
# nor a phone number is worse: the feed works, ads run, and every enquiry
# arrives with no way to answer it.
#
# New companies get a form at creation; this is for the ones that already
# exist.
#
# Reuses Websites::DefaultLeadForm.ensure_for, which returns an existing
# general-purpose form rather than making a second one, so this is safe to run
# repeatedly.
#
#   bin/rails intake:backfill_default_forms           # dry run
#   bin/rails intake:backfill_default_forms APPLY=1   # create them
namespace :intake do
  desc 'Create a contact form for any company lacking a reachable one (APPLY=1 to write)'
  task backfill_default_forms: :environment do
    apply = ENV['APPLY'].present?

    needs_form = Company.order(:id).select do |company|
      current = Websites::DefaultLeadForm.for(company)
      current.nil? || !Websites::DefaultLeadForm.reachable?(current)
    end

    if needs_form.empty?
      puts 'every company already has a form that collects an email or a phone number'
      next
    end

    puts "#{needs_form.length} companies need a reachable contact form"

    created = 0
    skipped = 0

    needs_form.each do |company|
      label = "#{company.id} #{company.name}"
      current = Websites::DefaultLeadForm.for(company)
      reason = current ? "best form ##{current.id} \"#{current.name}\" collects no email or phone" : 'no form at all'

      unless apply
        puts "  would create a contact form for #{label} (#{reason})"
        next
      end

      form = Websites::DefaultLeadForm.ensure_for(company)

      if form && form.id != current&.id
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
