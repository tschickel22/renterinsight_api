# frozen_string_literal: true

module Guide
  # Why one record came out the way it did, for the help assistant's
  # explain_record tool (E118 step 2). look_up says what a record is; this
  # says why: what a deal's gross and commission are made of, line by line,
  # what posted a journal entry, why an invoice or payment is or is not in the
  # books, where a bank line was booked, and where each agreement field gets
  # its value.
  #
  # Every figure comes from the model's own math (Deal#front_gross,
  # CommissionBasis, the posting services' own records), never recomputed
  # here. Every record is found through the same scoping the Claude connector
  # uses for its read tools, so a person can open here exactly what they can
  # open in the app; not found and not allowed read the same.
  #
  # Agreements return where each field comes from, never the values: some
  # agreements hold license numbers, birth dates and income.
  class ExplainRecord
    TYPES = %w[deal journal_entry invoice payment bank_transaction agreement].freeze
    NOT_FOUND = "I can't open that one. It may not exist, or your role or locations may not include it."

    def initialize(ctx)
      @ctx = ctx
      @company = ctx.company
    end

    def call(type, id)
      type = type.to_s
      return { error: "No record type #{type}. Use one of: #{TYPES.join(', ')}." } unless TYPES.include?(type)

      raw = id.to_s.split(':').last.to_s
      return { error: 'Give the record number, like 42 (deal:42 works too).' } unless raw.match?(/\A\d+\z/)

      result = send("explain_#{type}", raw.to_i)
      result.nil? ? { not_found: NOT_FOUND } : Guide::Fit.call(result, max_chars: 9_000)
    rescue McpTools::Denied => e
      { not_allowed: e.message }
    rescue ActiveRecord::RecordNotFound
      { not_found: NOT_FOUND }
    end

    private

    # ---- deal ----------------------------------------------------------------

    def explain_deal(id)
      deal = McpTools::Records.new(@ctx).scope('deal').find_by(id: id)
      return nil unless deal

      costs = @ctx.deal_costs_visible?
      {
        deal: "deal:#{deal.id}", name: deal.try(:name), stage: deal.stage,
        closed_on: (deal.try(:closed_at) || deal.try(:actual_close_date))&.to_date&.iso8601,
        location: @ctx.location_names[deal.location_id],
        people: fact { people(deal) },
        home: fact { home(deal, costs) },
        lines: fact { lines(deal, costs) },
        totals: fact { totals(deal) },
        gross: costs ? fact { gross(deal) } : 'Cost and gross are not shown: your role does not include deal cost details.',
        books: fact { deal_books(deal) },
        money_in: fact { money_in(deal) },
        commission: fact { commission(deal) },
        url: @ctx.app_url("/deals/#{deal.id}")
      }.compact
    end

    def people(deal)
      names = @ctx.user_names
      CommissionPaymentGeneratorService::ROLE_FIELDS.to_h do |role, field|
        [role, names[deal.public_send(field)]]
      end.compact
    end

    def home(deal, costs)
      v = deal.vehicle
      return 'No home is linked to this deal.' unless v

      {
        stock_number: v.stock_number, home: [v.year, v.make, v.model].compact.join(' '), status: v.status,
        condition: v.try(:condition), landed_cost: (costs ? money(deal.landed_cost) : nil),
        cost_entered: deal.cost_entered?, floor_plan: v.floor_plan_amount.to_d.positive? ? 'on floor plan' : nil
      }.compact
    end

    # The deal's lines as the commission worksheet sorts them (home, add-ons
    # by kind, F&I products), each with its price and tax, and its cost when
    # the person can see cost.
    def lines(deal, costs)
      taxes = deal.deal_products.to_h { |dp| [dp.id, dp.tax.to_d] }
      CommissionBasis.new(deal, deal.commission_plan || deal.determine_commission_plan).lines.map do |l|
        { name: l[:name], kind: l[:kind].to_s.tr('_', ' '), price: money(l[:price]), tax: money(taxes[l[:id]]),
          cost: (costs ? money(l[:cost]) : nil), margin: (costs ? money(l[:margin]) : nil) }.compact
      end
    end

    def totals(deal)
      {
        selling_price: money(deal.selling_price), line_tax: money(deal.deal_products.sum(:tax)),
        pack: (@ctx.deal_costs_visible? ? money(deal.effective_pack_amount) : nil)
      }.compact
    end

    def gross(deal)
      {
        front_gross: money(deal.front_gross), add_on_gross: money(deal.addon_gross),
        commissionable_front_gross: money(deal.commissionable_front_gross), house_profit: money(deal.house_profit),
        back_gross: money(deal.back_gross), total_gross: money(deal.total_gross),
        how_figured: 'See the how it works note "what commission is paid on" for what each figure includes.'
      }.compact
    end

    def deal_books(deal)
      unless deal.gl_posted?
        reasons = []
        reasons << 'the deal is not closed as won' unless deal.stage_is_won?
        reasons << 'it has a selling price but no home cost, so approval will refuse it' if deal.selling_price.to_d.positive? && !deal.cost_entered?
        notes = []
        notes << 'it has no selling price yet, so approving it would post no sale' if deal.selling_price.to_d.zero?
        return { approved_to_books: false,
                 next_step: 'It waits for approval under Accounting, Deals & Commissions, Pending GL Approval (Approve & Post to GL).',
                 blocking: reasons.presence, worth_checking: notes.presence }.compact
      end

      je = deal.gl_journal_entry_id && @company.journal_entries.find_by(id: deal.gl_journal_entry_id)
      { approved_to_books: true, approved_on: deal.try(:gl_posted_at)&.to_date&.iso8601,
        closing_entry: je && { id: "journal_entry:#{je.id}", number: je.entry_number, date: je.entry_date&.iso8601, void: je.is_void || nil }.compact }.compact
    end

    def money_in(deal)
      invoice = deal.deal_invoice
      receipts = CashReceipt.where(deal_id: deal.id, is_deleted: false, voided_at: nil)
      {
        sale_invoice: invoice && { id: "invoice:#{invoice.id}", number: invoice.invoice_number, status: invoice.status,
                                   total: money(invoice.total), paid: money(invoice.amount_paid), owed: money(invoice.amount_due) },
        deposits_and_payments: receipts.order(:receipt_date).limit(10).map do |r|
          { date: r.try(:receipt_date)&.iso8601, amount: money(r.amount), method: r.try(:payment_method), unapplied: money(r.try(:amount_unapplied)) }.compact
        end.presence
      }.compact
    end

    # Commission as the deal's Commission tab shows it, for people who can
    # read commissions (the worksheet's own rule).
    def commission(deal)
      return 'Not shown: your role does not include commissions.' unless @ctx.can?('commissions', 'read')

      chosen = deal.commission_plan
      plan = chosen || deal.determine_commission_plan
      basis = CommissionBasis.new(deal, plan)
      types = plan ? plan.commission_components.where(is_active: true).filter_map { |c| c.gross_type.presence || ('addon' if c.component_type == 'addon_commission') }.uniq : []
      types = ['commissionable_front'] if types.empty?
      payments = CommissionPayment.where(deal_id: deal.id, is_deleted: [false, nil]).order(:id)
      {
        plan: plan&.name || 'No plan applies to this deal.',
        plan_pays: plan && plan.commission_components.where(is_active: true).ordered.map { |c| { name: c.name, role: (c.applies_to_role || 'primary_salesperson').humanize, pays: c.calculation_description } },
        paid_payments_stand: 'A payment already paid keeps its amount if the deal changes later; more owed becomes a new payment, less owed is noted on the paid one.',
        why_this_plan: if chosen then 'chosen on the deal'
                       elsif plan then 'the plan for its salesperson, their role, or the company default'
                       end,
        figures: types.map { |t| explained_figure(basis.explain(t)) },
        payments: payments.map { |p| payment_line(p, plan) }.presence || 'No commission payments yet (they are made when the deal becomes payable).',
        adjustments: deal.commission_adjustments.active.map { |a| { person: @ctx.user_names[a.payee_user_id], amount: money(a.amount), reason: a.reason } }.presence,
        booked_in_books: (money(Accounting::DealCommissionAccrual.new(deal).booked_amount) if deal.gl_posted? && @ctx.can?('accounting', 'read'))
      }.compact
    end

    # A payment, with the plan it was figured under. One made under another
    # plan than the deal uses now (the plan changed after it was paid) says
    # so, rather than leaving the difference to be guessed at.
    def payment_line(payment, current_plan)
      paid_plan = payment.commission_plan_id && (@plan_names ||= @company.commission_plans.pluck(:id, :name).to_h)[payment.commission_plan_id]
      details = payment.try(:calculation_details)
      {
        person: @ctx.user_names[payment.payee_user_id], amount: money(payment.amount), status: payment.status,
        figured_under_plan: paid_plan,
        different_plan: (current_plan && payment.commission_plan_id && payment.commission_plan_id != current_plan.id) ?
          "Made under #{paid_plan || 'another plan'}, not #{current_plan.name} which the deal uses now; a paid payment keeps its amount." : nil,
        made_on: payment.created_at&.to_date&.iso8601, paid_on: (payment.try(:paid_date) || payment.paid_at)&.to_date&.iso8601,
        how_figured: details.is_a?(Hash) && details.any? ? details.to_json.first(600) : nil
      }.compact
    end

    def explained_figure(f)
      { figure: f[:label], amount: money(f[:amount]), cost_entered: f[:cost_entered],
        lines: Array(f[:rows]).map { |r| r.slice(:name, :kind_label, :price, :cost, :margin, :counts, :reason).compact }.first(25),
        steps: Array(f[:steps]).first(12) }.compact
    end

    # ---- journal entry -------------------------------------------------------

    def explain_journal_entry(id)
      McpTools::AccountingAccess.require!(@ctx, 'journal_entries', 'read')
      je = McpTools::GetJournalEntry.visible(@ctx).find_by(id: id)
      return nil unless je

      McpTools::AccountingAccess.journal_entry(@ctx, je).merge(posted_by_what: what_posted(je))
    end

    SOURCES = {
      'Deal' => 'approving the deal to the books (the closing entry), a change after approval, or its commission',
      'Invoice' => 'the invoice leaving draft (Auto-post invoices on)',
      'Payment' => 'a customer payment on an invoice',
      'CashReceipt' => 'money received on a deal or invoice (a deposit or Receive Payment)',
      'Bill' => 'the bill leaving draft (Post bill)',
      'BillPayment' => 'paying a bill',
      'BankTransaction' => 'categorizing a bank feed line',
      'Vehicle' => 'floor plan interest on a home, posted once a day',
      'PrintedCheck' => 'a printed check',
      'AccountingImport' => 'the QuickBooks switch (opening balances)',
      'FiscalPeriod' => 'Year-End Close'
    }.freeze

    def what_posted(je)
      return 'Entered by hand under Accounting, Journal Entries.' if je.source_entity_type.blank? && je.source_type != 'auto'

      SOURCES[je.source_entity_type] || "#{je.source_entity_type.to_s.underscore.humanize.downcase} #{je.source_entity_id}"
    end

    # ---- invoice -------------------------------------------------------------

    def explain_invoice(id)
      @ctx.authorize!('finance', 'read')
      invoice = McpTools::AccountingAccess.invoices(@ctx).find_by(id: id)
      return nil unless invoice

      McpTools::AccountingAccess.invoice(@ctx, invoice).merge(in_the_books: invoice_books(invoice))
    end

    def invoice_books(invoice)
      je = @company.journal_entries.where(source_entity_type: 'Invoice', source_entity_id: invoice.id, is_void: false).order(:id).first
      return { posted: true, entry: { id: "journal_entry:#{je.id}", number: je.entry_number, date: je.entry_date&.iso8601 } } if je

      settings = AccountingSettings.for_company(@company)
      deal_sale = invoice.source_type.to_s.in?(%w[Deal deal_close]) || (invoice.deal_id && Deal.where(id: invoice.deal_id, deal_invoice_id: invoice.id).exists?)
      why =
        if invoice.accounting_import_id.present? then 'It came over in the QuickBooks switch; the opening entry already holds what is owed.'
        elsif invoice.loan_id.present? then 'It is a loan installment; loan payments are not sales and never post as one.'
        elsif deal_sale then "It is the deal's sale invoice; the deal's closing entry books the sale when the deal is approved."
        elsif invoice.status == 'draft' then 'It is a draft. Invoices post when they leave draft (finalized or sent).'
        elsif !settings&.auto_post_invoices then 'Auto-post invoices is off in Accounting Settings.'
        elsif invoice.try(:gl_post_error).present? then "Posting failed: #{invoice.gl_post_error}"
        else 'It has not posted yet; it posts the next time its status changes or a payment on it posts.'
        end
      { posted: false, why: why }
    end

    # ---- payment -------------------------------------------------------------

    def explain_payment(id)
      @ctx.authorize!('finance', 'read')
      payment = @ctx.scope_locations(@company.payments.where(is_deleted: [false, nil]), include_unlocated: true).find_by(id: id)
      return nil unless payment

      je = @company.journal_entries.where(source_entity_type: 'Payment', source_entity_id: payment.id, is_void: false).order(:id).first
      invoice_ids = [payment.payable_type == 'Invoice' ? payment.payable_id : nil]
      invoice_ids += payment.payment_applications.where(applicable_type: 'Invoice').pluck(:applicable_id) if payment.respond_to?(:payment_applications)
      invoices = @company.invoices.where(id: invoice_ids.compact.uniq).to_a
      {
        payment: "payment:#{payment.id}", number: payment.try(:payment_number), date: payment.payment_date&.to_date&.iso8601,
        amount: money(payment.amount), status: payment.status, processing_fee: money(payment.try(:processing_fee)),
        fee_paid_by: payment.try(:fee_responsibility), refunded: payment.is_refunded ? money(payment.refund_amount) : nil,
        invoices: invoices.map { |i| { id: "invoice:#{i.id}", number: i.invoice_number } }.presence,
        bank_account: payment.bank_account_id && @company.bank_accounts.find_by(id: payment.bank_account_id)&.then { |b| McpTools::AccountingAccess.bank_account_label(b) },
        in_the_books: if je then { posted: true, entry: { id: "journal_entry:#{je.id}", number: je.entry_number } }
                      elsif payment.loan_id.present? then { posted: false, why: 'Loan installments do not post as invoice payments.' }
                      elsif payment.try(:gl_post_error).present? then { posted: false, why: "Posting failed: #{payment.gl_post_error}" }
                      elsif !AccountingSettings.for_company(@company)&.auto_post_payments then { posted: false, why: 'Auto-post payments is off in Accounting Settings.' }
                      else { posted: false, why: 'A payment posts only against an invoice already in the books; this one is not posted yet.' }
                      end
      }.compact
    end

    # ---- bank transaction ----------------------------------------------------

    def explain_bank_transaction(id)
      McpTools::AccountingAccess.require!(@ctx, 'bank_accounts_accounting', 'read')
      txn = McpTools::AccountingAccess.bank_transactions(@ctx).find_by(id: id)
      return nil unless txn

      meaning = {
        'posted' => 'Categorizing it posted a new entry for it.',
        'linked' => 'It was matched to an entry that already existed (an invoice payment, a bill, or an entry made by hand).',
        'not_posted' => 'It was categorized with no entry behind it, so the money is not in the books.'
      }
      base = McpTools::AccountingAccess.bank_txn(@ctx, txn)
      rule = txn.try(:rule_id) && @company.bank_rules.find_by(id: txn.rule_id)
      base.merge(
        what_that_means: meaning[base[:booked_by]] || (txn.status == 'excluded' ? 'Excluded: it posts nothing.' : 'Not booked yet: categorize, match or exclude it under Accounting, Bank Transactions.'),
        bank_rule: rule&.try(:name)
      ).compact
    end

    # ---- agreement -----------------------------------------------------------


    def explain_agreement(id)
      @ctx.authorize!('agreements', 'read')
      agreement = @ctx.scope_locations(@company.agreements.where(is_deleted: [false, nil]), include_unlocated: true).find_by(id: id)
      return nil unless agreement

      signers = agreement.agreement_signers.order(:signing_order, :id).to_a
      placements = Array(agreement.merge_field_placements.presence || agreement.field_placements)
      {
        agreement: "agreement:#{agreement.id}", title: agreement.title, number: agreement.agreement_number, status: agreement.status,
        template: agreement.agreement_template&.name, deal: agreement.deal_id && "deal:#{agreement.deal_id}",
        signers: signers.map.with_index { |s, i| { slot: i + 1, role: s.role, name: s.name, status: s.status }.compact },
        fields: placements.first(80).map { |p| field_source(p, signers) },
        note: 'Field values are not shown here. Open the agreement to see them.'
      }.compact
    end

    def field_source(placement, signers)
      p = placement.respond_to?(:to_h) ? placement.to_h.stringify_keys : {}
      key = p['fieldKey'].to_s
      signer = p['signerIndex'] && signers[p['signerIndex'].to_i]
      {
        label: p['fieldLabel'].presence || key, key: key, page: p['page'] && p['page'].to_i + 1,
        filled_from: Guide::FieldSources.describe(key, custom: p['isCustomField']),
        filled_by_signer: p['isSignerField'] ? (signer ? "slot #{p['signerIndex'].to_i + 1} (#{signer.role})" : "slot #{p['signerIndex'].to_i + 1}, no signer there") : nil
      }.compact
    end

    # ---- helpers -------------------------------------------------------------

    def money(value)
      value.nil? ? nil : value.to_d.round(2).to_f
    end

    # A savepoint, so one failed query never spoils the ones after it.
    def fact(&block)
      ActiveRecord::Base.transaction(requires_new: true, &block)
    rescue StandardError => e
      Rails.logger.info("[Guide::ExplainRecord] skipped a fact: #{e.class} #{e.message}")
      nil
    end
  end
end
