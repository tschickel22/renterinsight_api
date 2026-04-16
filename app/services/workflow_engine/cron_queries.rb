module WorkflowEngine
  module CronQueries
    QUERIES = {
      'stale_leads' => ->(company) {
        company.leads.where('updated_at < ?', 14.days.ago).where.not(status: %w[converted lost])
      },
      'unassigned_service_tickets' => ->(company) {
        company.service_tickets.where(assigned_to: nil)
      }
    }

    if defined?(Invoice) && Invoice.respond_to?(:column_names) && Invoice.column_names.include?('due_date')
      QUERIES['overdue_invoices'] = ->(company) {
        company.invoices.where('due_date < ?', Date.current).where.not(status: %w[paid cancelled void])
      }
    end

    QUERIES.freeze

    module_function

    def run(key, company)
      q = QUERIES[key.to_s]
      return [] unless q
      q.call(company)
    rescue => e
      Rails.logger.error "[CronQueries] #{key} failed: #{e.message}"
      []
    end
  end
end
