# frozen_string_literal: true

# Books commission on deals approved before commission was booked at approval
# (Accounting::DealCommissionAccrual, 2026-11-24). Before then most approved
# deals never had their commission booked, and some had it twice.
#
#   bin/rails commissions:backfill_accruals                 # dry run, every company
#   COMPANY_ID=2 bin/rails commissions:backfill_accruals    # dry run, one company
#   APPLY=1 COMPANY_ID=2 bin/rails commissions:backfill_accruals
#
# Each deal gets one entry dated its close date, or today when that period is
# closed, for the difference between what its commission payments add up to
# and what the books already hold. Running it twice books nothing more.
namespace :commissions do
  desc 'Book commission on approved deals whose commission is not in the books (dry run unless APPLY=1)'
  task backfill_accruals: :environment do
    apply = ENV['APPLY'] == '1'
    deals = Deal.where(gl_posted: true)
    deals = deals.where(company_id: ENV['COMPANY_ID']) if ENV['COMPANY_ID'].present?
    totals = Hash.new { |h, k| h[k] = { deals: 0, amount: 0.to_d } }

    deals.includes(:company).find_each do |deal|
      accrual = Accounting::DealCommissionAccrual.new(deal)
      difference = (accrual.owed_amount - accrual.booked_amount).round(2)
      next if difference.zero?

      line = "company #{deal.company_id} #{deal.company&.name} | deal #{deal.id} | owed #{accrual.owed_amount.to_s('F')} " \
             "| booked #{accrual.booked_amount.to_s('F')} | difference #{difference.to_s('F')}"
      if apply
        result = accrual.sync!
        line += result[:error] ? " | NOT BOOKED: #{result[:error]}" : " | booked entry #{result[:journal_entry]&.id}"
      end
      puts line
      totals[deal.company_id][:deals] += 1
      totals[deal.company_id][:amount] += difference
    end

    puts(apply ? 'Booked:' : 'Dry run (APPLY=1 to book):')
    totals.each { |company_id, t| puts "  company #{company_id}: #{t[:deals]} deals, #{t[:amount].to_s('F')}" }
    puts '  nothing to book' if totals.empty?
  end
end
