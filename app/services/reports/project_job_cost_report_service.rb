# frozen_string_literal: true

module Reports
  # Project job cost reports (E68 step 3): profitability per project, and
  # budget against committed, billed and paid cost per project and phase.
  #
  # Job cost is the project's cost lines (the Costs & Budget tab), which bills
  # keep in step: a contractor invoice, a cost line's draft bill and any posted
  # bill tagged to the project each have exactly one set of cost lines, so
  # nothing here is counted twice. Disputed cost lines (a voided bill, or one
  # the dealer marked) are shown but not counted.
  #
  # Profit starts from the deal's own front gross (Deal#front_gross, never
  # recomputed here). Delivery and setup are carrying costs outside front
  # gross, so taking job cost off it does not count them twice.
  class ProjectJobCostReportService
    STATUSES = %w[active completed on_hold cancelled].freeze

    def initialize(company)
      @company = company
    end

    def profitability(**filters)
      projects = scoped_projects(**filters).includes(:deal, :location).to_a
      costs = cost_buckets(projects.map(&:id))
      on_books = ledger_cost(projects.map(&:id))
      funding = DealFundingReportService.new(@company).rows_for(projects.map(&:deal_id).compact)
      invoiced = invoiced_by_project(projects.reject(&:deal_id).map(&:id))

      rows = projects.map do |project|
        c = costs.fetch(project.id, empty_bucket)
        job_cost = c[:committed] + c[:billed] + c[:paid]
        deal = project.deal
        billed = invoiced[project.id]
        # A project with no deal (an installer's linked job, E68) earns what it
        # invoices: that is its sale, and with no home cost, its front gross.
        sale_price = deal ? deal.selling_price&.to_d : billed&.dig(:revenue)
        front_gross = deal ? deal.front_gross&.to_d : billed&.dig(:revenue)
        after = front_gross && (front_gross - job_cost)
        budget = project.budget_amount&.to_d

        project_row(project).merge(
          deal_number: deal&.try(:deal_number),
          revenue_from: deal ? 'deal' : (billed ? 'invoices' : nil),
          sale_price: sale_price&.to_f,
          front_gross: front_gross&.to_f,
          budget: budget&.to_f,
          job_cost: job_cost.to_f,
          disputed: c[:disputed].to_f,
          budget_variance: budget && (budget - job_cost).to_f,
          on_books: on_books.fetch(project.id, 0).to_f,
          # What the customer has paid and still owes on the deal, or on the
          # project's own invoices (nil until there is an invoice).
          received: deal ? funding[project.deal_id]&.dig(:received) : billed&.dig(:received)&.to_f,
          owed: if deal
                  funding[project.deal_id] && (funding[project.deal_id][:invoice_id] ? funding[project.deal_id][:owed] : nil)
                else
                  billed&.dig(:owed)&.to_f
                end,
          after_job_cost: after&.to_f,
          margin: after && sale_price&.positive? ? (after / sale_price * 100).round(1).to_f : nil
        )
      end

      with_front = rows.reject { |r| r[:front_gross].nil? }
      total_after = with_front.sum { |r| r[:after_job_cost] }
      total_sales = with_front.sum { |r| r[:sale_price].to_f }
      {
        projects: rows,
        summary: {
          project_count: rows.size,
          total_sale_price: rows.sum { |r| r[:sale_price].to_f },
          total_budget: rows.sum { |r| r[:budget].to_f },
          total_job_cost: rows.sum { |r| r[:job_cost] },
          total_disputed: rows.sum { |r| r[:disputed] },
          total_on_books: rows.sum { |r| r[:on_books] },
          total_received: rows.sum { |r| r[:received].to_f },
          total_owed: rows.sum { |r| r[:owed].to_f },
          # After job cost and margin cover only projects whose deal has a
          # cost entered (Deal#front_gross is nil otherwise).
          gross_project_count: with_front.size,
          total_front_gross: with_front.sum { |r| r[:front_gross] },
          total_after_job_cost: total_after,
          margin: total_sales.positive? ? (total_after / total_sales * 100).round(1) : nil,
          over_budget_count: rows.count { |r| r[:budget_variance]&.negative? }
        }
      }
    end

    def budget(**filters)
      projects = scoped_projects(**filters).includes(:location, :project_phases).to_a
      ids = projects.map(&:id)
      by_project = cost_buckets(ids)
      by_phase = cost_buckets(ids, by_phase: true)

      rows = projects.map do |project|
        phases = project.project_phases.sort_by(&:position).map do |phase|
          budget_line(phase.name, phase.estimated_budget, by_phase.fetch([project.id, phase.id], empty_bucket))
            .merge(phase_id: phase.id, status: phase.status)
        end
        unphased = by_phase[[project.id, nil]]
        phases << budget_line('No phase', nil, unphased).merge(phase_id: nil, status: nil) if unphased

        project_row(project).merge(budget_line(nil, project.budget_amount, by_project.fetch(project.id, empty_bucket)).except(:name))
                            .merge(phases: phases)
      end

      keys = %i[budget committed billed paid disputed total]
      {
        projects: rows,
        summary: keys.index_with { |k| rows.sum { |r| r[k].to_f } }.merge(
          project_count: rows.size,
          remaining: rows.sum { |r| r[:remaining].to_f },
          over_budget_count: rows.count { |r| r[:remaining]&.negative? }
        )
      }
    end

    # Job cost per project (committed, billed and paid; disputed left out), for
    # other reports that show it beside their own figures.
    def job_cost_by_project(project_ids)
      cost_buckets(project_ids).transform_values { |c| c[:committed] + c[:billed] + c[:paid] }
    end

    private

    # Revenue billed from projects that have no deal: their own invoices that
    # have gone out (not drafts or cancelled), before tax.
    def invoiced_by_project(project_ids)
      return {} if project_ids.empty?

      @company.invoices.not_deleted
              .where(source_type: 'Project', source_id: project_ids)
              .where.not(status: %w[draft cancelled])
              .group(:source_id)
              .pluck(:source_id, Arel.sql('SUM(subtotal)'), Arel.sql('SUM(amount_paid)'), Arel.sql('SUM(total - amount_paid)'))
              .to_h { |id, revenue, received, owed| [id, { revenue: revenue.to_d, received: received.to_d, owed: owed.to_d }] }
    end

    def scoped_projects(status: nil, location_id: nil, start_date: nil, end_date: nil, project_id: nil)
      projects = @company.projects.not_deleted
      projects = projects.where(id: project_id) if project_id.present?
      statuses = Array(status).map(&:to_s) & STATUSES
      projects = statuses.any? ? projects.where(status: statuses) : projects.where.not(status: 'cancelled')
      projects = projects.where(location_id: location_id) if location_id.present?
      started = Arel.sql('COALESCE(projects.started_at, projects.created_at::date)')
      projects = projects.where('COALESCE(projects.started_at, projects.created_at::date) >= ?', start_date) if start_date
      projects = projects.where('COALESCE(projects.started_at, projects.created_at::date) <= ?', end_date) if end_date
      projects.order(started.desc, id: :desc)
    end

    def project_row(project)
      {
        id: project.id,
        project_number: project.project_number,
        name: project.name,
        customer_name: project.customer_name,
        status: project.status,
        deal_id: project.deal_id,
        location: project.location&.name,
        started_at: project.started_at || project.created_at&.to_date
      }
    end

    def empty_bucket
      { committed: 0.to_d, billed: 0.to_d, paid: 0.to_d, disputed: 0.to_d }
    end

    # Where each cost line stands, as money:
    # - committed: entered but not yet on a posted bill (no bill and pending,
    #   or only on a draft bill)
    # - billed: on a posted bill not yet paid, or approved without a bill
    # - paid: its bill is paid, or marked paid without one
    # - disputed: disputed, or its bill was voided
    def cost_buckets(project_ids, by_phase: false)
      return {} if project_ids.empty?

      group = by_phase ? %w[project_cost_items.project_id project_cost_items.project_phase_id] : %w[project_cost_items.project_id]
      bucket_sql = <<~SQL.squish
        CASE
          WHEN project_cost_items.status = 'disputed' OR bills.status = 'void' THEN 'disputed'
          WHEN bills.id IS NOT NULL AND bills.status = 'draft' THEN 'committed'
          WHEN bills.id IS NOT NULL AND bills.status = 'paid' THEN 'paid'
          WHEN bills.id IS NOT NULL THEN 'billed'
          WHEN project_cost_items.status = 'paid' THEN 'paid'
          WHEN project_cost_items.status = 'approved' THEN 'billed'
          ELSE 'committed'
        END
      SQL

      sums = ProjectCostItem.not_deleted
                            .where(company_id: @company.id, project_id: project_ids)
                            .joins('LEFT JOIN bills ON bills.id = project_cost_items.bill_id AND bills.is_deleted = FALSE')
                            .group(*group.map { |g| Arel.sql(g) }, Arel.sql(bucket_sql))
                            .sum(:amount)

      sums.each_with_object({}) do |(key, amount), out|
        *ids, bucket = key
        id = by_phase ? ids : ids.first
        (out[id] ||= empty_bucket)[bucket.to_sym] += amount.to_d
      end
    end

    # Expense posted to the ledger for each project, for checking job cost
    # against the books.
    def ledger_cost(project_ids)
      return {} if project_ids.empty?

      JournalEntryLine.joins(:journal_entry, :chart_of_account)
                      .merge(JournalEntry.in_ledger)
                      .where(journal_entries: { company_id: @company.id }, project_id: project_ids)
                      .where(chart_of_accounts: { account_type: 'expense' })
                      .group(:project_id)
                      .sum('journal_entry_lines.debit_amount - journal_entry_lines.credit_amount')
    end

    def budget_line(name, budget, bucket)
      bucket ||= empty_bucket
      total = bucket[:committed] + bucket[:billed] + bucket[:paid]
      {
        name: name,
        budget: budget&.to_d&.to_f,
        committed: bucket[:committed].to_f,
        billed: bucket[:billed].to_f,
        paid: bucket[:paid].to_f,
        disputed: bucket[:disputed].to_f,
        total: total.to_f,
        remaining: budget && (budget.to_d - total).to_f
      }
    end
  end
end
