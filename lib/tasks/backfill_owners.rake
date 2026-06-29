# Backfill owner_id propagation for converted-lead lineage. Three passes, run in
# order so each pass can feed the next:
#
#   1. Deal.owner_id → Account.owner_id  (account inherits from its newest deal)
#   2. Deal.owner_id → Contact.owner_id  (contact inherits from its newest deal)
#   3. Account.owner_id → Contact.owner_id (contacts inherit from their account)
#
# Idempotent and conservative: only fills BLANK owner_id values, never overwrites
# an existing assignment — a rep who already owns a record keeps it.
#
# Dry-run by default. Set RUN=1 to actually persist updates.
# Optional COMPANY_ID=N to scope to a single tenant.
#
#   bin/rails owners:backfill                   # dry run, all companies
#   bin/rails owners:backfill RUN=1             # apply, all companies
#   bin/rails owners:backfill COMPANY_ID=47     # dry run, single tenant
#   bin/rails owners:backfill RUN=1 COMPANY_ID=47

namespace :owners do
  desc 'Propagate owner_id from deals/accounts down to associated contacts/accounts (only fills blanks).'
  task backfill: :environment do
    apply = ENV['RUN'] == '1'
    company_id = ENV['COMPANY_ID'].presence&.to_i

    mode_banner = apply ? 'APPLY MODE — writes will persist' : 'DRY RUN — no writes (set RUN=1 to apply)'
    scope_banner = company_id ? "company_id=#{company_id}" : 'ALL companies'
    puts "owners:backfill  |  #{mode_banner}  |  #{scope_banner}"
    puts '-' * 80

    company_scope = company_id ? Company.where(id: company_id) : Company.all
    grand_totals = Hash.new(0)

    company_scope.find_each do |company|
      puts "\n--- Company ##{company.id} (#{company.name}) ---"
      totals = Hash.new(0)

      # Pass 1: Deal → Account
      # For each account with NULL owner_id, find the most recent deal that has an
      # owner_id and inherit from it. order(created_at: :desc) → take(1) is the
      # tie-break: newest deal reflects current rep assignment.
      company.accounts.where(owner_id: nil).find_each do |account|
        latest_deal = account.deals.where.not(owner_id: nil).order(created_at: :desc).first
        next unless latest_deal

        if apply
          account.update_columns(owner_id: latest_deal.owner_id, updated_at: Time.current)
        end
        totals[:account_from_deal] += 1
      end

      # Pass 2: Deal → Contact
      # Contacts can be associated with multiple deals via deal.contact_id. Pick the
      # newest deal that names this contact AND has an owner.
      company.contacts.where(owner_id: nil).find_each do |contact|
        latest_deal = Deal.where(company_id: company.id, contact_id: contact.id)
                          .where.not(owner_id: nil)
                          .order(created_at: :desc)
                          .first
        next unless latest_deal

        if apply
          contact.update_columns(owner_id: latest_deal.owner_id, updated_at: Time.current)
        end
        totals[:contact_from_deal] += 1
      end

      # Pass 3: Account → Contact (catches contacts whose account got an owner in
      # pass 1, AND contacts on already-owned accounts that never went through
      # conversion). Re-query owner_id IS NULL so pass 2's updates are reflected.
      already_set_contact_ids = []
      company.contacts.where(owner_id: nil).includes(:account).find_each do |contact|
        next unless contact.account&.owner_id

        if apply
          contact.update_columns(owner_id: contact.account.owner_id, updated_at: Time.current)
        end
        totals[:contact_from_account] += 1
        already_set_contact_ids << contact.id
      end

      puts format(
        '  account←deal: %5d   contact←deal: %5d   contact←account: %5d',
        totals[:account_from_deal], totals[:contact_from_deal], totals[:contact_from_account]
      )
      totals.each { |k, v| grand_totals[k] += v }
    end

    puts ''
    puts '=' * 80
    puts "TOTAL  account←deal: #{grand_totals[:account_from_deal]}"
    puts "TOTAL  contact←deal: #{grand_totals[:contact_from_deal]}"
    puts "TOTAL  contact←account: #{grand_totals[:contact_from_account]}"
    puts ''
    puts(apply ? 'Backfill APPLIED.' : 'DRY RUN complete — re-run with RUN=1 to persist.')
  end
end
