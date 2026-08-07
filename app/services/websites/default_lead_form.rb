# frozen_string_literal: true

module Websites
  # The intake form a generated site's contact block should submit to.
  #
  # projectProfile has accepted a leadFormId since it was written, and
  # SiteRenderer's contact block requires one, but nothing in production ever
  # passed it. So every demo and every committed site rendered "Contact form not
  # available" where the contact form should be, and the calculator's quote
  # button — which needs the same id — never appeared at all.
  #
  # The form MUST belong to the same company as the inventory embed token. The
  # public endpoint authenticates with that token and scopes the lookup to that
  # company (Api::Crm::Intake::FormsController#set_form), so a form borrowed
  # from anywhere else 404s. That is why this resolves from the lot company
  # rather than the profile's tenant.
  #
  # Preference order matters for a demo: a campaign form named "New Home Sales
  # Special — Lowest Prices in East Texas" is a real form, but showing it as the
  # contact form on a prospect's preview reads as someone else's marketing.
  class DefaultLeadForm
    # A form meant for "get in touch", rather than one built for a campaign.
    GENERAL_PURPOSE = /contact|get in touch|inquir|request info|more info|general/i

    # Campaign and channel forms. Real, but wrong for a contact block.
    CAMPAIGN_SPECIFIC = /facebook|google|instagram|tiktok|special|promo|sale|event|test/i

    def self.for(company)
      new(company).call
    end

    def initialize(company)
      @company = company
    end

    # @return [IntakeForm, nil]
    def call
      return nil if @company.nil?

      forms = active_forms
      return nil if forms.empty?

      forms.find { |f| GENERAL_PURPOSE.match?(f.name.to_s) } ||
        forms.find { |f| !CAMPAIGN_SPECIFIC.match?(f.name.to_s) } ||
        forms.first
    end

    private

    # Oldest first: a company's original form is the general one far more often
    # than its newest, which is usually whatever campaign shipped last.
    #
    # A form with no schema renders as an empty box, which looks more broken
    # than no form at all, so those are skipped.
    def active_forms
      @company.intake_forms.active.order(:created_at).to_a.select { |f| f.schema.present? }
    rescue StandardError => e
      Rails.logger.warn("[Websites::DefaultLeadForm] lookup failed for #{@company&.id}: #{e.message}")
      []
    end
  end
end
