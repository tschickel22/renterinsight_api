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
      'invoices'        => { model: 'Invoice',       scope: :invoices,        match_fields: %w[invoice_number],        label: 'Invoices',        supports_images: false }
    }.freeze

    EXCLUDED_COLUMN_PATTERNS = [
      /\Aid\z/, /\Acompany_id\z/, /\Acreated_at\z/, /\Aupdated_at\z/,
      /\Ais_deleted\z/, /\Adeleted_at\z/, /\Aencrypted_/, /_digest\z/, /_token\z/
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
      }
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

      # Dynamic field discovery — standard columns + custom fields.
      def fields_for(module_type, company_id: nil)
        klass = model_class(module_type)
        return [] unless klass

        required = required_fields_for(module_type)

        standard = klass.columns.reject { |c| excluded_column?(c.name) }.map do |col|
          {
            key: col.name,
            label: col.name.humanize,
            type: column_type(col),
            required: required.include?(col.name.to_sym) || required.include?(col.name),
            source: 'standard'
          }
        end

        custom = custom_fields_for(module_type, company_id)
        standard + custom
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

      def supports_images?(module_type)
        cfg = config_for(module_type)
        cfg ? cfg[:supports_images] == true : false
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

      def excluded_column?(name)
        EXCLUDED_COLUMN_PATTERNS.any? { |pat| name.match?(pat) }
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
