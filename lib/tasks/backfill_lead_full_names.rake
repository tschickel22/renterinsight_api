namespace :leads do
  desc <<~DESC
    Split leads whose whole name landed in first_name (last_name blank) into
    first + last. Scoped to one company. Dry-run by default.

      rake leads:split_full_names COMPANY_ID=17            # preview
      rake leads:split_full_names COMPANY_ID=17 APPLY=1    # write

    Inbound Facebook leads arrive this way when the Zap maps FB's single
    "Full name" field into first_name. Idempotent — safe to re-run.
  DESC
  task split_full_names: :environment do
    company_id = ENV['COMPANY_ID'].to_i
    abort 'COMPANY_ID is required (e.g. COMPANY_ID=17)' if company_id.zero?

    apply = ENV['APPLY'].present?

    scope = Lead.where(company_id: company_id)
                .where("last_name IS NULL OR last_name = ''")
                .where("first_name ~ '\\S\\s+\\S'") # at least two words

    total = scope.count
    puts "Company #{company_id}: #{total} lead(s) with a multi-word first_name and no last_name"
    puts(apply ? 'APPLY=1 — writing changes' : 'Dry run — pass APPLY=1 to write')
    puts

    changed = 0
    scope.find_each do |lead|
      head, *rest = lead.first_name.to_s.strip.split(/\s+/)
      last = rest.join(' ')
      next if head.blank? || last.blank?

      puts format('  #%-8s %-30s -> %-15s | %s', lead.id, lead.first_name, head, last)
      # update_columns: this is a data correction, not lead activity — it should
      # not bump last_activity_at or fire the workflow/notification callbacks
      # that a real edit does.
      lead.update_columns(first_name: head, last_name: last) if apply
      changed += 1
    end

    puts
    puts(apply ? "Done. Updated #{changed} lead(s)." : "Would update #{changed} lead(s).")
  end
end
