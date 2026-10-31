# frozen_string_literal: true

# Fills the gaps the help article screenshots showed in a demo company
# (backlog E89): the screens a help article shows should look like a
# dealership's, not empty or upside down.
#
#   bin/rails runner script/demo/fill_help_screens.rb 5            # preview
#   bin/rails runner script/demo/fill_help_screens.rb 5 --apply    # write
#
# Staging's Summit Park (company 5) only: the company must be is_demo and in
# DEMO_REFRESH_COMPANY_IDS, which is set on staging alone. Safe to re-run:
# each piece is skipped when it is already there. Records are created
# directly, never through the controllers, so no email or text goes out.
#
#   - Opening balances on 30 Sep. The QuickBooks opening entry was voided on
#     4 Oct while testing and never replaced, so cash and inventory ran
#     negative and the Balance Sheet showed negative total assets.
#   - September's bank reconciliation on Wells Fargo checking, completed.
#   - Three recurring journal entries (rent, insurance, depreciation).
#   - Two commission payments, one paid and one approved.
#   - A bid request on a Denver project with two bids in and one waiting.
#   - The tour-check account (GUIDE_CHECK_EMAIL), which takes the pictures,
#     gets a person's name instead of "Tour Checker".

company_id = ARGV[0].to_i
apply = ARGV.include?('--apply')
company = Company.find(company_id)
unless company.is_demo? && DemoRefresh.company_ids.include?(company.id)
  abort "Company #{company.id} is not a demo company in DEMO_REFRESH_COMPANY_IDS on this server; nothing done."
end

puts apply ? "APPLYING to #{company.name}" : "PREVIEW for #{company.name} (add --apply to write)"
OPENING_MEMO = 'Opening balances as of 30 Sep 2026'
SEPT_END = Date.new(2026, 9, 30)
denver = company.locations.find_by!(name: 'Denver Showroom')
account = ->(number) { company.chart_of_accounts.find_by!(account_number: number) }
admin = company.users.where(role: 'admin').order(:id).first || company.users.order(:id).first

def say(done, what) = puts("#{done ? 'skip' : 'add '}  #{what}")

ActiveRecord::Base.transaction do
  # --- Opening balances -----------------------------------------------------
  lines = [
    ['1010', 186_500, 0], ['1030', 50_000, 0], ['1210', 612_400, 0], ['1230', 24_850, 0], ['1410', 96_000, 0],
    ['2110', 0, 428_000], ['2520', 0, 60_000], ['3000', 0, 481_750]
  ]
  opening = company.journal_entries.in_ledger.find_by(memo: OPENING_MEMO)
  say(opening, "opening balance entry, #{lines.sum { |_, dr, _| dr }.to_fs(:delimited)} each side")
  if apply && !opening
    opening = company.journal_entries.build(entry_date: SEPT_END, memo: OPENING_MEMO, source_type: 'manual', posted_by: admin)
    # Recording balances the closed period already had, not new activity.
    opening.allow_closed_period = true
    lines.each_with_index do |(number, dr, cr), i|
      opening.journal_entry_lines.build(chart_of_account: account.call(number), debit_amount: dr, credit_amount: cr,
                                        location_id: denver.id, memo: 'Opening balance', position: i)
    end
    opening.save!
  end

  # --- September bank reconciliation ----------------------------------------
  bank = company.bank_accounts.find_by(chart_of_account_id: account.call('1010').id)
  rec = bank && company.bank_reconciliations.find_by(bank_account: bank, statement_date: SEPT_END)
  bank ? say(rec, "September reconciliation on #{bank.bank_name} checking, completed") : puts('miss  reconciliation: no bank account on 1010')
  if apply && bank && !rec
    checking_lines = JournalEntryLine.joins(:journal_entry)
                                     .merge(company.journal_entries.in_ledger)
                                     .where(chart_of_account_id: bank.chart_of_account_id)
                                     .where(journal_entries: { entry_date: ..SEPT_END })
    ending = checking_lines.sum('debit_amount - credit_amount')
    rec = company.bank_reconciliations.create!(bank_account: bank, statement_date: SEPT_END, beginning_balance: 0,
                                               statement_ending_balance: ending, notes: 'September statement')
    checking_lines.find_each do |line|
      rec.bank_reconciliation_items.create!(journal_entry_line: line, cleared: true, amount: line.debit_amount - line.credit_amount)
    end
    raise "September reconciliation does not balance: #{rec.difference}" unless rec.complete!(admin)
  end

  # --- Recurring journal entries --------------------------------------------
  [
    ['Showroom lot lease', '6200', '1010', 4_800, 'Monthly lot lease, Denver showroom'],
    ['Business insurance', '6400', '1310', 1_250, 'Insurance used this month from the prepaid annual policy'],
    ['Depreciation: vehicles & equipment', '6800', '1490', 1_600, 'Straight-line depreciation']
  ].each do |name, debit, credit, amount, memo|
    found = company.recurring_journal_entries.find_by(name: name)
    say(found, "recurring entry: #{name}, $#{amount.to_fs(:delimited)} monthly")
    next if !apply || found

    company.recurring_journal_entries.create!(
      name: name, frequency: 'monthly', next_run_date: Date.new(2026, 11, 1), auto_post: true, is_active: true, memo: memo,
      template_lines: [
        { chart_of_account_id: account.call(debit).id, debit_amount: amount, credit_amount: 0, memo: memo, location_id: denver.id },
        { chart_of_account_id: account.call(credit).id, debit_amount: 0, credit_amount: amount, memo: memo, location_id: denver.id }
      ]
    )
  end

  # --- Commission payments ----------------------------------------------------
  plan = company.commission_plans.order(:id).find_by(name: 'Standard 2026') || company.commission_plans.order(:id).first
  [
    { deal: '2024 Fleetwood Estate Series - William Johnson', amount: 3_748.65, status: 'paid' },
    { deal: '2024 Fleetwood Pinehurst - Elizabeth Brown', amount: 425.00, status: 'approved' }
  ].each do |c|
    deal = company.deals.find_by(name: c[:deal])
    next puts("miss  commission: no deal #{c[:deal]}") unless deal&.owner_id

    found = company.commission_payments.where("metadata ->> 'demo_key' = ?", "help-#{deal.id}").exists?
    say(found, "commission payment, #{c[:status]}, $#{c[:amount]} on #{deal.name}")
    next if !apply || found

    payment = company.commission_payments.create!(
      deal: deal, payee_user_id: deal.owner_id, commission_plan: plan, amount: c[:amount], status: c[:status],
      earned_date: Date.new(2026, 10, 16), location_id: deal.location_id || denver.id, metadata: { demo_key: "help-#{deal.id}" },
      approved_by_user_id: admin.id, approved_at: Time.zone.parse('2026-10-20 10:00'),
      **(c[:status] == 'paid' ? { paid_by_user_id: admin.id, paid_at: Time.zone.parse('2026-10-24 10:00'), payment_method: 'direct_deposit',
                                  paid_date: Date.new(2026, 10, 24), amount_paid: c[:amount], payment_reference: 'Payroll 10/24' } : {})
    )
    payment.commission_payment_line_items.create!(description: 'Front gross', calculation_basis: 'front_gross',
                                                  calculation_method: 'percentage', rate: 25, basis_amount: (c[:amount] * 4).round(2),
                                                  calculated_amount: c[:amount], display_order: 0)
  end

  # --- A bid request with bids ----------------------------------------------
  project = company.projects.joins(:deal).where(status: 'active', deals: { location_id: denver.id }).order(:id).first
  # A site-work phase if the project has one still to do, else its next phase.
  open_phases = project&.project_phases&.where(status: 'not_started')&.order(:position)
  phase = open_phases&.where("name ILIKE ANY (ARRAY['%install%', '%set%', '%site%', '%finish%'])")&.first || open_phases&.first
  contractors = company.vendors.only_contractors.order(:id).limit(3).to_a
  title = 'Skirting and steps'
  found = project && company.project_bid_requests.exists?(project: project, title: title)
  if project.nil? || phase.nil? || contractors.size < 2
    puts 'miss  bid request: no Denver project with an open phase, or fewer than two contractors'
  else
    say(found, "bid request '#{title}' on #{project.name}, #{phase.name}: 2 bids in, #{contractors.size - 2} waiting")
    if apply && !found
      request = company.project_bid_requests.create!(project: project, project_phase: phase, title: title, status: 'open',
                                                     scope: 'Vinyl skirting all sides, two sets of steps with rails.',
                                                     bids_due_on: Date.new(2026, 11, 7), start_wanted_on: Date.new(2026, 11, 16),
                                                     created_by_id: admin.id)
      [[4_250, 5], [3_980, 7]].each_with_index do |(amount, days), i|
        request.bids.create!(company: company, vendor: contractors[i], status: 'submitted', amount: amount,
                                     duration_days: days, can_start_on: Date.new(2026, 11, 16) + i.days,
                                     invited_at: Time.zone.parse('2026-10-28 09:00'), submitted_at: Time.zone.parse("2026-10-#{29 + i} 14:00"),
                                     entered_by_id: admin.id)
      end
      contractors.drop(2).each do |vendor|
        request.bids.create!(company: company, vendor: vendor, status: 'invited', invited_at: Time.zone.parse('2026-10-28 09:00'),
                                     entered_by_id: admin.id)
      end
    end
  end

  # --- The account that takes the pictures ------------------------------------
  checker = company.users.find_by('lower(email) = ?', ENV['GUIDE_CHECK_EMAIL'].to_s.downcase.strip)
  renamed = checker.nil? || checker.first_name != 'Tour'
  say(renamed, "rename #{checker&.email || 'the tour-check account (not in this company)'} to Jordan Ellis")
  checker.update!(first_name: 'Jordan', last_name: 'Ellis') if apply && !renamed

  # --- The books still tie ----------------------------------------------------
  if apply
    bs = Reports::BalanceSheetReportService.new(company).generate(as_of_date: Date.current)
    tb = Reports::TrialBalanceReportService.new(company).generate(as_of_date: Date.current)
    ties = bs[:total_assets] == bs[:total_liabilities] + bs[:total_equity] && tb[:total_debits] == tb[:total_credits]
    puts "Balance sheet: assets #{bs[:total_assets]}, liabilities #{bs[:total_liabilities]}, equity #{bs[:total_equity]}; trial balance #{tb[:total_debits]} / #{tb[:total_credits]}"
    raise 'The books do not tie; rolled back' unless ties
  end
end
puts apply ? 'Done.' : 'Nothing written.'
