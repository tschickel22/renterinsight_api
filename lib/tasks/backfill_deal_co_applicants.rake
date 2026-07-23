# Backfill deals.co_applicant_contact_id for deals converted from a lead before
# the FK existed.
#
# Lead conversion has always created a second Contact on the account from the
# lead's co_applicant_* fields, tagged with a "Co-applicant converted from lead
# #<id>" note. Nothing linked it to the deal, so the co-borrower was reachable
# from the Account and invisible on the Deal.
#
# Match strategy (scoped to the deal's own account, so there is no cross-account
# risk):
#   1. Prefer the co-applicant note stamped by the conversion path — unambiguous.
#   2. Fall back to a lone non-primary contact on the account.
# Anything with 0 or 2+ candidates is REPORTED, never written. An account with
# several non-primary contacts (a spouse plus a realtor, say) cannot be resolved
# by heuristic and is left for a human.
#
# DRY-RUN by default. Set APPLY=1 to write. COMPANY_ID=<id> to scope.
#
#   bin/rails deals:backfill_co_applicants                        # dry-run, all
#   COMPANY_ID=17 bin/rails deals:backfill_co_applicants          # dry-run, co 17
#   COMPANY_ID=17 APPLY=1 bin/rails deals:backfill_co_applicants  # write, co 17
namespace :deals do
  desc "Backfill deals.co_applicant_contact_id from converted-lead co-applicant contacts. DRY-RUN by default; APPLY=1 to write; COMPANY_ID=<id> to scope."
  task backfill_co_applicants: :environment do
    apply      = ENV['APPLY'] == '1'
    company_id = ENV['COMPANY_ID'].presence

    mode = apply ? 'APPLY' : 'DRY-RUN'
    puts "[deals:backfill_co_applicants] mode=#{mode} company_id=#{company_id || 'ALL'}"

    scope = Deal.where(co_applicant_contact_id: nil).where.not(account_id: nil)
    scope = scope.where(company_id: company_id) if company_id

    linked = 0
    no_candidate = 0
    ambiguous = []

    scope.find_each do |deal|
      candidates = Contact.where(account_id: deal.account_id, company_id: deal.company_id)
                          .where(is_deleted: [false, nil])

      # 1. The conversion path stamps this note. Trust it over any heuristic.
      noted = candidates.where("notes ILIKE ?", '%Co-applicant converted from lead #%')

      picked =
        if noted.count == 1
          noted.first
        elsif noted.count > 1
          nil # several co-applicants on one account — needs a human
        else
          # 2. Fall back to a single non-primary contact.
          others = candidates.where(is_primary: [false, nil])
          others = others.where.not(id: deal.contact_id) if deal.contact_id
          others.count == 1 ? others.first : nil
        end

      if picked
        puts "  deal #{deal.id} (account #{deal.account_id}) -> contact #{picked.id} #{picked.first_name} #{picked.last_name}".rstrip
        deal.update_column(:co_applicant_contact_id, picked.id) if apply
        linked += 1
      else
        pool = candidates.where(is_primary: [false, nil])
        pool = pool.where.not(id: deal.contact_id) if deal.contact_id
        if pool.count.zero?
          no_candidate += 1
        else
          ambiguous << [deal.id, deal.account_id, pool.count]
        end
      end
    end

    puts ""
    puts "[deals:backfill_co_applicants] linked=#{linked} no_candidate=#{no_candidate} ambiguous=#{ambiguous.size}"

    if ambiguous.any?
      puts "[deals:backfill_co_applicants] SKIPPED (ambiguous — resolve by hand):"
      ambiguous.each { |deal_id, account_id, n| puts "  deal #{deal_id} account #{account_id} has #{n} non-primary contacts" }
    end

    puts "[deals:backfill_co_applicants] DRY-RUN — nothing written. Re-run with APPLY=1." unless apply
  end
end
