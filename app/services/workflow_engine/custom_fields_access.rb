# frozen_string_literal: true

# WorkflowEngine::CustomFieldsAccess
#
# Shared helper for reading/writing custom fields from workflow step executors,
# the condition evaluator, and the variable resolver. Custom fields live in the
# JSONB `custom_field_values` column on most CRM entities, keyed by
# `CustomField#field_key` and scoped by `CustomField#module`.
#
# Before this module existed, executors like UpdateField called
# `entity.update!(next_appointment: '2026-07-17')` and blew up with
# ActiveRecord::UnknownAttributeError because `next_appointment` is a custom
# field, not a real column. Read paths silently returned nil for the same
# reason. Route through here to make both work.
module WorkflowEngine
  module CustomFieldsAccess
    module_function

    # Which `custom_fields.module` string to look up for a given entity class.
    # Entities not in this map either don't support custom fields
    # (ServiceTicket uses a different `custom_fields` JSON column with no
    # CustomField metadata) or aren't yet targeted by workflows.
    ENTITY_MODULE_MAP = {
      'Lead'    => 'leads',
      'Account' => 'accounts',
      'Contact' => 'contacts',
      'Deal'    => 'deals',
      'Vehicle' => 'inventory_mh'
    }.freeze

    # Does this entity's table have the `custom_field_values` JSONB column?
    # Cheaper than rescuing NoMethodError inside each caller.
    def supports_custom_fields?(entity)
      entity.present? &&
        entity.class.column_names.include?('custom_field_values') &&
        ENTITY_MODULE_MAP.key?(entity.class.name)
    end

    # Field keys defined as custom fields for this entity's module + company.
    # Cached per-request via Current for hot code paths (variable resolution
    # walks this for every {{path}} miss).
    def custom_field_keys(entity)
      return [] unless supports_custom_fields?(entity)

      company_id = entity.respond_to?(:company_id) ? entity.company_id : nil
      return [] if company_id.nil?

      mod = ENTITY_MODULE_MAP[entity.class.name]
      # Thread.current keys must be strings/symbols; serialize to keep the
      # per-request cache scoped by (company, module) without allocating an
      # array key that Thread.current rejects.
      cache = (Thread.current[:workflow_custom_fields_cache] ||= {})
      cache["#{company_id}:#{mod}"] ||= CustomField
        .where(company_id: company_id, module: mod, is_active: true)
        .pluck(:field_key)
    end

    # Split an attributes hash into { real:, custom: } so callers can
    # `entity.update!(real)` and merge `custom` into `custom_field_values`.
    def partition(entity, attrs)
      return { real: attrs.dup, custom: {} } unless supports_custom_fields?(entity)

      cf_keys = custom_field_keys(entity).map(&:to_s)
      real = {}
      custom = {}
      attrs.each do |k, v|
        k_s = k.to_s
        if cf_keys.include?(k_s)
          custom[k_s] = v
        else
          real[k] = v
        end
      end
      { real: real, custom: custom }
    end

    # Merge-and-save a set of custom-field values without clobbering the rest of
    # the JSONB blob. Uses `deep_stringify_keys` per the JSONB-metadata rule in
    # CLAUDE.md so we don't leave symbol keys behind that break dedup elsewhere.
    def write(entity, custom_values)
      return false if custom_values.blank?
      return false unless supports_custom_fields?(entity)

      current = (entity.custom_field_values || {}).deep_stringify_keys
      entity.update!(custom_field_values: current.merge(custom_values.deep_stringify_keys))
      true
    end

    # Look up a single custom field value for an entity by field_key.
    def read(entity, key)
      return nil unless supports_custom_fields?(entity)

      values = entity.custom_field_values
      return nil if values.blank?

      key_s = key.to_s
      values[key_s] || values[key_s.to_sym]
    end
  end
end
