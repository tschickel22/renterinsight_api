# frozen_string_literal: true

module ImportExport
  # Central registry of all modules supported by the import/export engine.
  # Field discovery is dynamic — it introspects ActiveRecord columns and
  # merges in custom fields, so adding a column auto-exposes it to import/export.
  class ModuleRegistry
    MODULES = {
      'accounts'        => { model: 'Account',       scope: :accounts,        match_fields: %w[name email],            label: 'Accounts',        supports_images: true  },
      'contacts'        => { model: 'Contact',       scope: :contacts,        match_fields: %w[email],                 label: 'Contacts',        supports_images: true  },
      'leads'           => { model: 'Lead',          scope: :leads,           match_fields: %w[email phone],           label: 'Leads',           supports_images: false },
      'deals'           => { model: 'Deal',          scope: :deals,           match_fields: %w[name],                  label: 'Deals',           supports_images: false },
      # NOTE: 'vehicles' (Homes) intentionally excluded — handled by the existing
      # dedicated vehicle importer which already supports image uploads.
      'parts'           => { model: 'Part',          scope: :parts,           match_fields: %w[sku barcode],           label: 'Parts',           supports_images: true  },
      'service_tickets' => { model: 'ServiceTicket', scope: :service_tickets, match_fields: %w[ticket_number],         label: 'Service Tickets', supports_images: true  },
      'quotes'          => { model: 'Quote',         scope: :quotes,          match_fields: %w[quote_number],          label: 'Quotes',          supports_images: false },
      'invoices'        => { model: 'Invoice',       scope: :invoices,        match_fields: %w[invoice_number],        label: 'Invoices',        supports_images: false },
      'budget_lines'    => { model: 'BudgetLine',    scope: :budget_lines,    match_fields: %w[account_number],        label: 'Budget Lines',    supports_images: false,
                             requires_context: true, context_params: %w[budget_id] }
    }.freeze

    EXCLUDED_COLUMN_PATTERNS = [
      /\Aid\z/, /\Acompany_id\z/, /\Acreated_at\z/, /\Aupdated_at\z/,
      /\Ais_deleted\z/, /\Adeleted_at\z/, /\Aencrypted_/, /_digest\z/, /_token\z/,
      /\Acustom_field_values\z/
    ].freeze

    # Columns excluded additionally for import (users can't provide internal FK IDs)
    IMPORT_EXCLUDED_PATTERNS = [
      /_id\z/  # All foreign keys — location_id, owner_id, source_id, etc.
    ].freeze

    # Per-module overrides for how `*_id` foreign-key columns resolve to a
    # human-readable value at export time. Keyed by the DB column. `attr` is
    # the method called on the associated record; if it returns nil we fall
    # back through DISPLAY_ATTR_FALLBACKS. Anything not listed here is handled
    # by auto-inference (see association_display_for).
    ASSOCIATION_DISPLAYS = {
      'accounts' => {
        'location_id'       => { association: :location,       attr: :name },
        'source_id'         => { association: :source,         attr: :name },
        'owner_id'          => { association: :owner,          attr: :name },
        'parent_account_id' => { association: :parent_account, attr: :name }
      },
      'contacts' => {
        'account_id'  => { association: :account,  attr: :name },
        'location_id' => { association: :location, attr: :name },
        'owner_id'    => { association: :owner,    attr: :name }
      },
      'leads' => {
        'location_id'          => { association: :location,          attr: :name },
        'source_id'            => { association: :source,            attr: :name },
        'owner_id'             => { association: :owner,             attr: :name },
        'converted_account_id' => { association: :converted_account, attr: :name },
        'vehicle_id'           => { association: :vehicle,           attr: :name }
      },
      'deals' => {
        'location_id'              => { association: :location,              attr: :name },
        'account_id'               => { association: :account,               attr: :name },
        'contact_id'               => { association: :contact,               attr: :name },
        'user_id'                  => { association: :user,                  attr: :name },
        'owner_id'                 => { association: :owner,                 attr: :name },
        'territory_id'             => { association: :territory,             attr: :name },
        'source_id'                => { association: :source,                attr: :name },
        'vehicle_id'               => { association: :vehicle,               attr: :name },
        'commission_plan_id'       => { association: :commission_plan,       attr: :name },
        'primary_salesperson_id'   => { association: :primary_salesperson,   attr: :name },
        'sales_manager_id'         => { association: :sales_manager,         attr: :name },
        'finance_manager_id'       => { association: :finance_manager,       attr: :name },
        'desk_manager_id'          => { association: :desk_manager,          attr: :name },
        'secondary_salesperson_id' => { association: :secondary_salesperson, attr: :name }
      },
      'parts' => {
        'category_id'      => { association: :category,      attr: :name },
        'created_by_id'    => { association: :created_by,    attr: :name },
        'updated_by_id'    => { association: :updated_by,    attr: :name },
        'factory_id'       => { association: :factory,       attr: :name },
        'floor_plan_id'    => { association: :floor_plan,    attr: :name }
      },
      'service_tickets' => {
        'location_id' => { association: :location, attr: :name },
        'account_id'  => { association: :account,  attr: :name },
        'contact_id'  => { association: :contact,  attr: :name },
        'vehicle_id'  => { association: :vehicle,  attr: :name },
        'deal_id'     => { association: :deal,     attr: :name }
      },
      'quotes' => {
        'location_id'  => { association: :location,  attr: :name },
        'account_id'   => { association: :account,   attr: :name },
        'contact_id'   => { association: :contact,   attr: :name },
        'vehicle_id'   => { association: :vehicle,   attr: :name },
        'deal_id'      => { association: :deal,      attr: :name },
        'sales_rep_id' => { association: :sales_rep, attr: :name }
      },
      'invoices' => {
        'location_id'  => { association: :location,  attr: :name },
        'contact_id'   => { association: :contact,   attr: :name },
        'listing_id'   => { association: :listing,   attr: :name },
        'deal_id'      => { association: :deal,      attr: :name },
        'loan_id'      => { association: :loan,      attr: :name },
        'quote_id'     => { association: :quote,     attr: :name },
        'sales_rep_id' => { association: :sales_rep, attr: :name }
      },
      'budget_lines' => {
        'chart_of_account_id' => { association: :chart_of_account, attr: :account_number },
        'budget_id'           => { association: :budget,           attr: :name }
      }
    }.freeze

    # ---------------------------------------------------------------------------
    # IMPORT LOOKUP FIELDS
    # Virtual fields shown only during import. The user provides a human-readable
    # value (e.g. account name, user email) and the Importer resolves it to the
    # corresponding `_id` column by searching within the company scope.
    #
    # key:           Virtual column key used in mapping / row hash
    # label:         Shown in the column-mapping UI
    # target_column: The real DB column to set (e.g. account_id)
    # model:         AR class to search
    # scope:         Company association to search within (nil = use model directly)
    # search_fields: Array of columns to ILIKE match against (first match wins)
    # ---------------------------------------------------------------------------
    LOOKUP_FIELDS = {
      # --- Shared across many modules ---
      # `auto_create: true` means the Importer will create the record on the fly
      # when the value doesn't match an existing row. Reserved for low-risk, freely-
      # creatable entities (sources, accounts, categories, contacts). Users,
      # locations, vehicles, and deals are never auto-created — too sensitive.
      'account_name'        => { label: 'Account (by name)',        target_column: 'account_id',    model: 'Account',  scope: :accounts,   search_fields: %w[name],           auto_create: true },
      'contact_email'       => { label: 'Contact (by email)',       target_column: 'contact_id',    model: 'Contact',  scope: :contacts,   search_fields: %w[email],          auto_create: true },
      'contact_name'        => { label: 'Contact (by name)',        target_column: 'contact_id',    model: 'Contact',  scope: :contacts,   search_fields: %w[first_name last_name], auto_create: true },
      'owner_email'         => { label: 'Owner (by email)',         target_column: 'owner_id',      model: 'User',     scope: :users,      search_fields: %w[email] },
      'owner_name'          => { label: 'Owner (by name)',          target_column: 'owner_id',      model: 'User',     scope: :users,      search_fields: %w[name email] },
      'location_name'       => { label: 'Location (by name)',       target_column: 'location_id',   model: 'Location', scope: :locations,  search_fields: %w[name code] },
      'source_name'         => { label: 'Source (by name)',         target_column: 'source_id',     model: 'Source',   scope: :sources,    search_fields: %w[name],           auto_create: true },
      'vehicle_stock'       => { label: 'Vehicle (by stock #)',     target_column: 'vehicle_id',    model: 'Vehicle',  scope: :vehicles,   search_fields: %w[stock_number] },
      'vehicle_vin'         => { label: 'Vehicle (by VIN)',         target_column: 'vehicle_id',    model: 'Vehicle',  scope: :vehicles,   search_fields: %w[vin] },
      'salesperson_email'   => { label: 'Salesperson (by email)',   target_column: 'primary_salesperson_id', model: 'User', scope: :users, search_fields: %w[email] },
      'category_name'       => { label: 'Category (by name)',      target_column: 'category_id',   model: 'PartCategory', scope: :part_categories, search_fields: %w[name], auto_create: true },
      'deal_name'           => { label: 'Deal (by name)',          target_column: 'deal_id',       model: 'Deal',   scope: :deals,    search_fields: %w[name deal_number] },
      'sales_rep_email'     => { label: 'Sales Rep (by email)',    target_column: 'sales_rep_id',  model: 'User',   scope: :users,    search_fields: %w[email] },
      'sales_rep_name'      => { label: 'Sales Rep (by name)',     target_column: 'sales_rep_id',  model: 'User',   scope: :users,    search_fields: %w[name email] },
      # --- Budget lines (Chart of Account lookups, distinct from CRM Account lookups above) ---
      'account_number'      => { label: 'Account Number',          target_column: 'chart_of_account_id', model: 'ChartOfAccount', scope: :chart_of_accounts, search_fields: %w[account_number] },
      'coa_account_name'    => { label: 'Account Name (CoA)',      target_column: 'chart_of_account_id', model: 'ChartOfAccount', scope: :chart_of_accounts, search_fields: %w[name] },
    }.freeze

    # Modules whose target model is `has_many :tag_assignments, as: :entity`.
    # The import engine exposes a virtual 'tags' column for these so users can
    # bulk-assign tags from a CSV (pipe- or comma-separated). Vehicles use a
    # separate dedicated importer and aren't listed here.
    TAGGABLE_MODULES = %w[accounts contacts leads deals quotes].freeze

    # Which lookup fields are available per module (keyed by the `_id` columns
    # that actually exist on the model).
    MODULE_LOOKUPS = {
      'accounts'        => %w[location_name source_name owner_email owner_name],
      'contacts'        => %w[account_name location_name owner_email owner_name],
      'leads'           => %w[location_name source_name owner_email owner_name vehicle_stock vehicle_vin],
      'deals'           => %w[account_name contact_email contact_name owner_email owner_name location_name source_name vehicle_stock vehicle_vin salesperson_email],
      'parts'           => %w[category_name],
      'service_tickets' => %w[account_name contact_email contact_name location_name vehicle_stock vehicle_vin deal_name],
      'quotes'          => %w[account_name contact_email contact_name location_name vehicle_stock vehicle_vin deal_name sales_rep_email sales_rep_name],
      'invoices'        => %w[contact_email contact_name location_name deal_name sales_rep_email sales_rep_name],
    }.freeze

    # Ordered list of attributes to try when resolving an association to a
    # display value — first non-blank wins.
    DISPLAY_ATTR_FALLBACKS = %i[name full_name display_name title label email].freeze

    class << self
      def available_modules
        MODULES.map { |key, cfg| { key: key, label: cfg[:label], model: cfg[:model] } }
      end

      def config_for(module_type)
        MODULES[module_type.to_s]
      end

      def model_class(module_type)
        cfg = config_for(module_type)
        return nil unless cfg
        cfg[:model].safe_constantize
      end

      # Dynamic field discovery — standard columns + custom fields + lookup fields.
      # Pass for_import: true to exclude foreign key _id columns and add lookup fields.
      def fields_for(module_type, company_id: nil, for_import: false)
        # Modules that don't follow the standard column-introspection pattern
        # supply their own field list (e.g. budget_lines has a fixed monthly
        # column layout that doesn't match the CSV format dealers upload).
        custom_override = custom_fields_override(module_type)
        return custom_override if custom_override

        klass = model_class(module_type)
        return [] unless klass

        required = required_fields_for(module_type)

        standard = klass.columns.reject { |c| excluded_column?(c.name, for_import: for_import) }.map do |col|
          {
            key: col.name,
            label: col.name.humanize,
            type: column_type(col),
            required: required.include?(col.name.to_sym) || required.include?(col.name),
            source: 'standard'
          }
        end

        custom = custom_fields_for(module_type, company_id)

        # Add virtual lookup fields for import (e.g. "Account (by name)" → account_id)
        lookups = for_import ? lookup_fields_for(module_type) : []

        # Add virtual 'tags' field for taggable modules on import.
        tag_field = (for_import && taggable?(module_type)) ? [tag_field_definition] : []

        standard + custom + lookups + tag_field
      end

      # Hardcoded fields for modules that don't follow the standard
      # ActiveRecord column-introspection flow. Returns nil for normal modules.
      def custom_fields_override(module_type)
        case module_type.to_s
        when 'budget_lines'
          [
            { key: 'account_number', label: 'Account Number', type: 'string',   required: true,  source: 'standard' },
            { key: 'account_name',   label: 'Account Name',   type: 'string',   required: false, source: 'standard' },
            { key: 'month_1',        label: 'Month 1 (Jan)',  type: 'currency', required: false, source: 'standard' },
            { key: 'month_2',        label: 'Month 2 (Feb)',  type: 'currency', required: false, source: 'standard' },
            { key: 'month_3',        label: 'Month 3 (Mar)',  type: 'currency', required: false, source: 'standard' },
            { key: 'month_4',        label: 'Month 4 (Apr)',  type: 'currency', required: false, source: 'standard' },
            { key: 'month_5',        label: 'Month 5 (May)',  type: 'currency', required: false, source: 'standard' },
            { key: 'month_6',        label: 'Month 6 (Jun)',  type: 'currency', required: false, source: 'standard' },
            { key: 'month_7',        label: 'Month 7 (Jul)',  type: 'currency', required: false, source: 'standard' },
            { key: 'month_8',        label: 'Month 8 (Aug)',  type: 'currency', required: false, source: 'standard' },
            { key: 'month_9',        label: 'Month 9 (Sep)',  type: 'currency', required: false, source: 'standard' },
            { key: 'month_10',       label: 'Month 10 (Oct)', type: 'currency', required: false, source: 'standard' },
            { key: 'month_11',       label: 'Month 11 (Nov)', type: 'currency', required: false, source: 'standard' },
            { key: 'month_12',       label: 'Month 12 (Dec)', type: 'currency', required: false, source: 'standard' },
            { key: 'notes',          label: 'Notes',          type: 'string',   required: false, source: 'standard' }
          ]
        end
      end

      # True for modules that require additional context params (e.g. budget_id
      # for budget_lines) on top of the file/module selection. The UI uses this
      # to prompt for the required selectors before allowing upload.
      def requires_context?(module_type)
        cfg = config_for(module_type)
        cfg ? cfg[:requires_context] == true : false
      end

      def context_params(module_type)
        cfg = config_for(module_type)
        return [] unless cfg
        Array(cfg[:context_params])
      end

      def required_fields_for(module_type)
        klass = model_class(module_type)
        return [] unless klass
        klass.validators
             .select { |v| v.is_a?(ActiveModel::Validations::PresenceValidator) }
             .flat_map(&:attributes)
             .map(&:to_s)
             .uniq
      rescue StandardError
        []
      end

      # Returns lookup field definitions for a module (used during import).
      def lookup_fields_for(module_type)
        keys = MODULE_LOOKUPS[module_type.to_s] || []
        keys.filter_map do |key|
          cfg = LOOKUP_FIELDS[key]
          next unless cfg
          {
            key: key,
            label: cfg[:label],
            type: 'string',
            required: false,
            source: 'lookup',
            target_column: cfg[:target_column],
            search_fields: cfg[:search_fields],
            model: cfg[:model],
            scope: cfg[:scope],
            auto_create: cfg[:auto_create] == true
          }
        end
      end

      def supports_images?(module_type)
        cfg = config_for(module_type)
        cfg ? cfg[:supports_images] == true : false
      end

      def taggable?(module_type)
        TAGGABLE_MODULES.include?(module_type.to_s)
      end

      # Virtual import-only field definition for tags. Pipe- or comma-
      # separated CSV values are parsed by the Importer, then resolved
      # against the company's Tags (case-insensitive find-or-create) and
      # attached via TagAssignment.
      def tag_field_definition
        {
          key:         'tags',
          label:       'Tags',
          type:        'string',
          required:    false,
          source:      'tag',
          placeholder: 'Pipe- or comma-separated. Example: VIP|Hot Lead|Trade Show'
        }
      end

      def image_association(module_type)
        case module_type.to_s
        when 'vehicles', 'parts', 'accounts', 'contacts', 'service_tickets'
          :images
        end
      end

      # Resolves a `*_id` column to the association + display attr(s) the
      # Exporter should dereference. Returns nil if the column isn't a
      # resolvable foreign key (e.g. polymorphic, or no matching reflection).
      def association_display_for(module_type, field_key)
        return nil if field_key.nil?
        key = field_key.to_s
        return nil unless key.end_with?('_id')

        explicit = ASSOCIATION_DISPLAYS.dig(module_type.to_s, key)
        if explicit
          attrs = Array(explicit[:attr]).compact
          return { association: explicit[:association], attrs: (attrs + DISPLAY_ATTR_FALLBACKS).uniq }
        end

        klass = model_class(module_type)
        return nil unless klass
        reflection = klass.reflect_on_all_associations(:belongs_to).find { |r| r.foreign_key.to_s == key }
        return nil unless reflection
        return nil if reflection.polymorphic?

        { association: reflection.name, attrs: DISPLAY_ATTR_FALLBACKS }
      end

      private

      def excluded_column?(name, for_import: false)
        return true if EXCLUDED_COLUMN_PATTERNS.any? { |pat| name.match?(pat) }
        return true if for_import && IMPORT_EXCLUDED_PATTERNS.any? { |pat| name.match?(pat) }
        false
      end

      def column_type(col)
        case col.type
        when :integer, :bigint then 'integer'
        when :decimal, :float  then 'decimal'
        when :boolean          then 'boolean'
        when :date             then 'date'
        when :datetime, :time  then 'datetime'
        when :json, :jsonb     then 'json'
        else 'string'
        end
      end

      def custom_fields_for(module_type, company_id)
        return [] unless defined?(CustomField)
        return [] unless company_id

        CustomField.where(company_id: company_id, module: module_type, is_active: true).map do |cf|
          {
            key: cf.field_key,
            label: cf.label.presence || cf.name,
            type: cf.field_type,
            required: cf.required == true,
            source: 'custom'
          }
        end
      rescue StandardError
        []
      end
    end
  end
end
