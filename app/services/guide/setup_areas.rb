# frozen_string_literal: true

module Guide
  # How a dealership has set up each part of the product, for the help
  # assistant's my_setup tool (E118). One entry for EVERY PlatformModule key:
  # spec/services/guide/setup_areas_spec.rb fails when a module has none, so a
  # new module cannot ship without someone deciding what help can read about
  # it.
  #
  # Each entry names the RBAC resource whose read permission the module's own
  # screens need, and the facts to read. Facts are named one by one: never a
  # whole Setting blob, because some (communications) hold SMTP passwords, AWS
  # keys and Twilio auth tokens. Each fact runs on its own, so one failing
  # lookup never costs the rest.
  #
  # Modules customers ask about most have a reader of their own
  # (Guide::Setup::Accounting, Guide::Setup::Commissions); the rest read a few
  # plain facts here.
  class SetupAreas
    NOT_OFFERED = 'Not offered. DealerTide does not have this today.'

    AREAS = {
      # CRM and sales
      'crm.prospecting' => { resource: 'leads', facts: %i[lead_sources lead_statuses intake_forms custom_fields_leads marketing_consent lead_feeds] },
      'crm.accounts' => { resource: 'crm', facts: %i[your_terms custom_fields_accounts account_count] },
      'crm.contacts' => { resource: 'crm', facts: %i[your_terms custom_fields_contacts contact_count] },
      'crm.deals' => { resource: 'deals', facts: %i[deal_stages custom_fields_deals fee_templates package_templates lenders] },
      'crm.quotes' => { resource: 'quotes', facts: %i[quote_defaults] },
      'sales.configurator' => { resource: 'configurator', facts: %i[truebuild_factories markup_rules surcharge_rules truebuild_addons] },
      'sales.truebuild_embed' => { resource: 'configurator', facts: %i[embed_inventory] },
      'sales.deal_desk' => { resource: 'deal_desk', facts: %i[lender_programs fni_products deal_desk_writeback] },

      # Inventory
      'inventory.vehicles' => { resource: 'inventory', facts: %i[inventory_by_status inventory_by_location custom_fields_vehicles] },
      'inventory.parts' => { resource: 'parts', facts: %i[part_categories suppliers reorder_rules] },
      'inventory.land' => { resource: 'inventory', facts: %i[land_parcels land_home_packages] },
      'inventory.lot_map' => { not_offered: true },
      'inventory.pdi' => { not_offered: true },
      'inventory.delivery' => { not_offered: true },
      'inventory.champion_ims' => { resource: 'inventory', facts: %i[champion_retailers champion_lead_feeds] },
      'inventory.manufacturer_catalog' => { resource: 'inventory', facts: %i[catalog_subscriptions] },

      # Marketing
      'marketing.listings' => { resource: 'listings', facts: %i[listing_count syndication_partners] },
      'marketing.brochures' => { resource: 'listings', facts: %i[brochure_count] },
      'marketing.website' => { resource: 'websites', facts: %i[websites domains] },
      'marketing.syndication' => { resource: 'listings', facts: %i[syndication_partners] },
      'marketing.social_media' => { resource: 'social_posts', facts: %i[facebook_page social_accounts] },
      'marketing.campaigns' => { resource: 'campaigns', facts: %i[campaign_counts audiences email_sending] },
      'marketing.automation' => { resource: 'campaigns', facts: %i[campaign_counts] },
      'marketing.landing_pages' => { resource: 'websites', facts: %i[websites] },
      'marketing.text_us' => { resource: 'websites', facts: %i[texting] },
      'marketing.lead_assistant' => { resource: 'company_settings', facts: %i[lead_assistant texting] },
      'marketing.proactive_outreach' => { resource: 'company_settings', facts: %i[lead_assistant] },
      'marketing.ai_concierge' => { resource: 'company_settings', facts: %i[lead_assistant] },
      'marketing.sending_domain' => { resource: 'company_settings', facts: %i[email_sending] },

      # Finance
      'finance.loans' => { resource: 'loans', facts: %i[loan_counts] },
      'finance.agreements' => { resource: 'agreements', facts: %i[agreement_templates] },
      'finance.invoices' => { resource: 'invoices', facts: %i[invoice_posting invoice_templates draw_schedules] },
      'finance.documents' => { resource: 'documents', facts: %i[document_storage] },
      'finance.applications' => { resource: 'finance', facts: %i[lenders] },
      'finance.accounting' => { resource: 'accounting', reader: 'Guide::Setup::Accounting' },

      # Service
      'service.operations' => { resource: 'service', facts: %i[service_issue_templates open_tickets] },
      'service.portal' => { resource: 'portal', facts: %i[portal_modules] },
      'service.warranty' => { resource: 'warranty_claims', facts: %i[warranty_claim_counts manufacturers] },

      # Management
      'management.reports' => { resource: 'reports', facts: %i[saved_reports ai_report_allowance] },
      'management_ai_reports' => { resource: 'management_ai_reports', facts: %i[ai_report_allowance] },
      'management.commissions' => { resource: 'commission_plans', reader: 'Guide::Setup::Commissions' },
      'management.tags' => { resource: 'settings', facts: %i[tags] },
      'management.tasks' => { resource: 'tasks', facts: %i[open_tasks] },
      'management.calendar' => { resource: 'calendar', facts: %i[business_hours your_email_connection] },
      'management.contractors' => { resource: 'contractors', facts: %i[contractors] },
      'management.projects' => { resource: 'projects', facts: %i[project_templates project_counts] },
      'management.linked_companies' => { resource: 'projects', facts: %i[linked_installers] },
      'management.workflows' => { resource: 'workflow_automation', facts: %i[workflows nurture_sequences] },
      'management.territories' => { resource: 'settings', facts: %i[territories] },

      # Administration
      'admin.settings' => { resource: 'company_settings', facts: %i[company_profile your_terms business_hours texting email_sending] },
      'admin.users' => { resource: 'users', facts: %i[users_by_role] },
      'admin.locations' => { resource: 'locations', facts: %i[locations] },
      'admin.roles' => { resource: 'users', facts: %i[roles] },
      'admin.api_keys' => { resource: 'integrations', facts: %i[api_keys] },
      'admin.webhooks' => { resource: 'integrations', facts: %i[webhooks] },
      'admin.ai_connector' => { resource: 'ai_connector', facts: %i[ai_connector] },
      'admin.platform' => { platform_only: true }
    }.freeze

    def self.keys
      AREAS.keys
    end

    # module name for the tool description: "crm.deals (Sales Pipeline)"
    def self.catalog
      AREAS.keys.map { |k| "#{k} (#{PlatformModule::MODULES.dig(k, :name)})" }.join(', ')
    end

    def initialize(ctx)
      @ctx = ctx
      @company = ctx.company
      @user = ctx.user
    end

    def call(key)
      area = AREAS[key.to_s]
      return { error: "No module #{key}. Use one of the listed module keys." } unless area

      name = PlatformModule::MODULES.dig(key.to_s, :name)
      return { plan_module: name, not_offered: NOT_OFFERED } if area[:not_offered]
      return { plan_module: name, note: 'Platform administration is for DealerTide staff only.' } if area[:platform_only]
      unless ModuleAccessService.new(@company).has_module?(key.to_s)
        return { plan_module: name, on_plan: false, note: "#{name} is not on this account's plan. An admin can ask about adding it." }
      end
      unless @ctx.can?(area[:resource], 'read')
        return { plan_module: name, not_allowed: "Your role does not include #{name}. Your admin can help." }
      end

      facts = area[:reader] ? area[:reader].constantize.new(@ctx).to_h : read_facts(area[:facts])
      Guide::Fit.call({ plan_module: name, on_plan: true }.merge(facts), max_chars: 6_000)
    end

    private

    def read_facts(names)
      names.each_with_object({}) do |n, out|
        value = fact { send(n) }
        out[n] = value unless value.nil?
      end
    end

    # A savepoint, so one failed query never spoils the ones after it.
    def fact(&block)
      ActiveRecord::Base.transaction(requires_new: true, &block)
    rescue StandardError => e
      Rails.logger.info("[Guide::SetupAreas] skipped a fact: #{e.class} #{e.message}")
      nil
    end

    def live(rel)
      cols = rel.klass.column_names
      rel = rel.where(is_deleted: [false, nil]) if cols.include?('is_deleted')
      rel = rel.where(deleted_at: nil) if cols.include?('deleted_at')
      rel
    end

    def active(rel)
      cols = rel.klass.column_names
      rel = live(rel)
      rel = rel.where(is_active: true) if cols.include?('is_active')
      rel = rel.where(active: true) if cols.include?('active')
      rel
    end

    def names(rel, column = :name, limit: 25)
      list = active(rel).order(column).limit(limit + 1).pluck(column).compact
      list.size > limit ? list.first(limit) + ["and more"] : list
    end

    def setting(key)
      Setting.get('Company', @company.id, key, nil)
    end

    def custom_fields(module_name)
      active(@company.custom_fields.for_module(module_name)).order(:label).limit(30).pluck(:label)
    end

    # ---- facts -------------------------------------------------------------

    def your_terms
      (@company.resolved_labels || {}).slice('lead', 'leads', 'deal', 'deals', 'vehicle', 'vehicles', 'account', 'contact')
    end

    def lead_sources = names(@company.sources)
    def lead_statuses = names(@company.lead_statuses, :label)
    def intake_forms = names(@company.intake_forms)
    def marketing_consent = setting('require_marketing_consent') ? 'a separate marketing consent box is required on forms' : 'not required'
    def lead_feeds = { champion: @company.champion_lead_feed_configs.count }
    def account_count = live(@company.accounts).count
    def contact_count = live(@company.contacts).count
    def custom_fields_accounts = custom_fields('accounts')
    def custom_fields_contacts = custom_fields('contacts')
    def custom_fields_deals = custom_fields('deals')
    def custom_fields_vehicles = custom_fields(%w[inventory inventory_mh inventory_rv])
    def custom_fields_leads = custom_fields('leads')

    def deal_stages
      @company.pipeline_stages.map { |s| s['label'] || s[:label] || s['name'] || s[:name] || s['key'] || s[:key] }.compact
    end

    def fee_templates
      active(@company.fee_templates).order(:position).limit(30).map do |f|
        { name: f.name, type: f.fee_type, default_amount: f.default_amount&.to_f, taxable: f.taxable }.compact
      end
    end

    def package_templates = names(@company.package_templates)
    def lenders = names(@company.lenders)

    def quote_defaults
      q = setting('quotes') || {}
      { default_tax_rate: q['defaultTaxRate'], valid_for_days: q['defaultValidityDays'],
        has_default_terms: q['defaultTermsConditions'].present? }.compact
    end

    def truebuild_factories = @company.dealer_factories.count
    def markup_rules = @company.dealer_markup_rules.count
    def surcharge_rules = @company.dealer_surcharge_rules.count
    def truebuild_addons = active(@company.truebuild_addons).count
    def embed_inventory = (setting('embed_inventory_config') || {}).is_a?(Hash) ? 'set up' : 'not set up'
    def lender_programs
      active(@company.lender_programs).order(:position).limit(25).map { |p| [p.lender_name, p.program_name].compact.join(': ') }
    end
    def fni_products = names(@company.fni_products)
    def deal_desk_writeback = setting('deal_desk_writeback_mode') || 'default'

    def inventory_by_status = live(@company.vehicles).group(:status).count
    def inventory_by_location
      counts = live(@company.vehicles).group(:location_id).count
      counts.transform_keys { |id| id ? (location_names[id] || "location #{id}") : 'no location' }
    end

    def location_names = @location_names ||= @company.locations.pluck(:id, :name).to_h

    def part_categories = names(@company.part_categories)
    def suppliers = names(@company.suppliers)
    def reorder_rules = @company.reorder_rules.count
    def land_parcels = live(@company.land_parcels).count
    def land_home_packages = live(@company.land_home_packages).count
    def champion_retailers = @company.champion_ims_retailers.count
    def champion_lead_feeds = @company.champion_lead_feed_configs.count
    def catalog_subscriptions = @company.dealer_catalog_subscriptions.count

    def listing_count = live(@company.listings).count
    def syndication_partners = names(@company.syndication_partners)
    def brochure_count = live(@company.brochures).count

    def websites
      live(@company.websites).order(updated_at: :desc).limit(5).map do |w|
        { name: w.try(:name), status: w.try(:status), subdomain: w.try(:subdomain) }.compact
      end
    end

    def domains = @company.company_domains.limit(10).pluck(:hostname)

    def facebook_page
      page = FacebookIntegration.current_for(@company)
      page.nil? ? 'not connected' : (page.token_expired? ? 'connected but expired, needs reconnecting' : 'connected')
    end

    def social_accounts = @company.social_accounts.group(:platform).count
    def campaign_counts = live(@company.campaigns).group(:status).count
    def audiences = names(@company.audiences)

    # Named fields only: this setting also holds SMTP passwords and AWS keys.
    def email_sending
      email = ((setting('communications') || {})['email'] || {})
      { provider: email['provider'], from_email: email['fromEmail'], from_name: email['fromName'],
        enabled: email['isEnabled'] }.compact
    end

    # Named fields only: this setting also holds the Twilio auth token.
    def texting
      sms = ((setting('communications') || {})['sms'] || {})
      numbers = @company.twilio_accounts.order(:id).map do |t|
        { number: t.phone_number, status: t.status, location: t.location_id ? location_names[t.location_id] : 'whole company' }
      end
      { from_number_in_settings: sms['fromNumber'], enabled: sms['isEnabled'], connected_numbers: numbers }.compact
    end

    def lead_assistant
      ModuleAccessService.new(@company).has_module?('marketing.lead_assistant') ? 'on the plan; settings under Marketing, Quinn AI' : 'not on the plan'
    end

    def loan_counts = live(@company.loans).group(:status).count

    def agreement_templates
      live(@company.agreement_templates).order(:name).limit(30).map do |t|
        signers = Array(t.default_signers).map { |s| s.is_a?(Hash) ? (s['role'] || s['label'] || s['type']) : s }.compact
        { name: t.name, status: t.status, form: [t.form_type, t.form_number].compact.join(' ').presence,
          signers: signers.presence, fields_mapped: Array(t.merge_field_placements).size }.compact
      end
    end

    def invoice_posting
      s = AccountingSettings.for_company(@company)
      s ? { invoices_post_to_books_automatically: s.auto_post_invoices, payments_post_automatically: s.auto_post_payments } : 'accounting not set up'
    end

    def invoice_templates = { terms: @company.invoice_terms_templates.count, notes: @company.invoice_notes_templates.count }
    def draw_schedules = names(@company.draw_schedule_templates)
    def document_storage = 'documents are stored privately and opened by signed link'

    def service_issue_templates = names(@company.service_issue_templates, :title)
    def open_tickets = live(@company.service_tickets).group(:status).count
    def portal_modules = setting('portal_modules') || 'defaults'
    def warranty_claim_counts = live(@company.warranty_claims).group(:status).count
    def manufacturers
      Manufacturer.where(id: @company.company_manufacturers.select(:manufacturer_id)).order(:name).limit(25).pluck(:name)
    end

    def saved_reports = live(@company.reports).count
    def ai_report_allowance = AiQueryLog.monthly_limit_for(@company, user: @user)
    def tags = names(@company.tags)
    def open_tasks = live(@company.tasks).group(:status).count

    def business_hours
      ops = setting('operational_settings') || setting('operational') || {}
      { timezone: ops['timezone'], business_hours: ops['business_hours'] }.compact
    end

    def your_email_connection = UserEmailConnection.where(user_id: @user.id).active.exists? ? 'connected' : 'not connected'
    def contractors = live(@company.contractors).count

    def linked_installers
      CompanyLink.where(dealer_company_id: @company.id).includes(:installer_company).map do |l|
        { installer: l.installer_company&.name || 'invited, not accepted yet', status: l.status }
      end
    end
    def project_templates = names(@company.project_templates)
    def project_counts = live(@company.projects).group(:status).count
    def workflows = live(@company.workflow_rules).count
    def nurture_sequences = names(@company.nurture_sequences)
    def territories = names(@company.territories)

    def company_profile
      (setting('company_profile') || {}).slice('business_description', 'industry_vertical', 'brand_voice', 'target_audience', 'products_services')
                                        .compact_blank.presence || 'not filled in'
    end

    def users_by_role
      @company.users.where(status: 'active').group(:role).count
    end

    def locations
      @company.locations.where(active: true, is_deleted: false).order(:name).pluck(:name)
    end

    def roles = @company.roles.order(:name).limit(40).pluck(:name)
    def api_keys = live(@company.api_keys).count
    def webhooks = @company.webhook_endpoints.count
    def ai_connector = ModuleAccessService.new(@company).has_module?('admin.ai_connector') ? 'available' : 'not on plan'
  end
end
