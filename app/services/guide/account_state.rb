# frozen_string_literal: true

module Guide
  # Facts about how this dealership has set things up, so the help assistant
  # can answer for their account rather than in general: "your deal stages are
  # Lead, Quoted, Sold" or "QuickBooks is not connected yet" (Tom, 2026-10-11:
  # dealers do not write articles, but help should read their settings).
  #
  # Read-only, and only facts a member of the company could see for
  # themselves. Each fact is computed on its own so one failing lookup never
  # costs the rest.
  class AccountState
    def initialize(user, company)
      @user = user
      @company = company
    end

    def to_h
      {
        company: @company.name,
        industry: @company.try(:industry),
        your_terms: fact { (@company.resolved_labels || {}).slice('lead', 'leads', 'deal', 'deals', 'vehicle', 'vehicles', 'account', 'contact') },
        deal_stages: fact { @company.pipeline_stages.map { |s| s['label'] || s[:label] || s['name'] || s[:name] || s['key'] || s[:key] }.compact },
        locations: fact { @company.locations.where(active: true, is_deleted: false).pluck(:name) },
        active_users: fact { @company.users.where(status: 'active').count },
        quickbooks: fact { QuickbooksConnection.where(company_id: @company.id).any?(&:connected?) ? 'connected' : 'not connected' },
        bank_accounts: fact { @company.bank_accounts.active.count },
        website: fact { website },
        texting_number: fact { @company.twilio_accounts.active.exists? ? 'set up' : 'not set up' },
        your_email_connected: fact { UserEmailConnection.where(user_id: @user.id).active.exists? },
        your_role: fact { @user.try(:roles)&.map(&:name)&.join(', ').presence || @user.role },
        modules_on_plan: fact { ModuleAccessService.new(@company).enabled_modules.first(60) }
      }.compact
    end

    private

    def website
      site = @company.websites.order(updated_at: :desc).first
      return 'none' unless site

      site.status == 'published' ? 'published' : "not published (#{site.status})"
    end

    def fact
      yield
    rescue StandardError => e
      Rails.logger.info("[Guide::AccountState] skipped a fact: #{e.class} #{e.message}")
      nil
    end
  end
end
