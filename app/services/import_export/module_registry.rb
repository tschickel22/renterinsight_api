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
      'vehicles'        => { model: 'Vehicle',       scope: :vehicles,        match_fields: %w[vin stock_number],      label: 'Homes',           supports_images: true  },
      'parts'           => { model: 'Part',          scope: :parts,           match_fields: %w[sku barcode],           label: 'Parts',           supports_images: true  },
      'service_tickets' => { model: 'ServiceTicket', scope: :service_tickets, match_fields: %w[ticket_number],         label: 'Service Tickets', supports_images: true  },
      'quotes'          => { model: 'Quote',         scope: :quotes,          match_fields: %w[quote_number],          label: 'Quotes',          supports_images: false },
      'invoices'        => { model: 'Invoice',       scope: :invoices,        match_fields: %w[invoice_number],        label: 'Invoices',        supports_images: false }
    }.freeze

    EXCLUDED_COLUMN_PATTERNS = [
      /\Aid\z/, /\Acompany_id\z/, /\Acreated_at\z/, /\Aupdated_at\z/,
      /\Ais_deleted\z/, /\Adeleted_at\z/, /\Aencrypted_/, /_digest\z/, /_token\z/
    ].freeze

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
