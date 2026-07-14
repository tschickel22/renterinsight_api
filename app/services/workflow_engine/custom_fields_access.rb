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
#
# Alias matching: rule builders (AI or human) commonly pass the display name
# ("Next Appointment") instead of the canonical field_key ("next_appointment").
# Both forms are accepted — resolve_field_key normalizes each side (downcase,
# strip, whitespace/dashes → underscores) and always writes back under the
# canonical field_key so the JSONB stays clean.
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

    # Canonical field_keys defined for this entity's module + company.
    # Kept as a bare Array so existing callers that iterate keys still work.
    def custom_field_keys(entity)
      alias_map(entity).values.uniq
    end

    # Normalized alias → canonical field_key map. Recognizes:
    #   - the exact field_key ("next_appointment")
    #   - the display name ("Next Appointment", "next appointment")
    #   - loose variants (spaces/dashes ↔ underscores, mixed case)
    # Cached per-request in Thread.current since resolve_field_key is called
    # for every {{path}} miss during variable resolution.
    def alias_map(entity)
      return {} unless supports_custom_fields?(entity)

      company_id = entity.respond_to?(:company_id) ? entity.company_id : nil
      return {} if company_id.nil?

      mod = ENTITY_MODULE_MAP[entity.class.name]
      cache = (Thread.current[:workflow_custom_fields_alias_cache] ||= {})
      cache["#{company_id}:#{mod}"] ||= build_alias_map(company_id, mod)
    end

    def build_alias_map(company_id, mod)
      map = {}
      CustomField
        .where(company_id: company_id, module: mod, is_active: true)
        .pluck(:field_key, :name)
        .each do |field_key, name|
          canonical = field_key.to_s
          [canonical, name.to_s].each do |candidate|
            key = normalize_alias(candidate)
            map[key] = canonical if key.present?
          end
        end
      map
    end

    # Fold whitespace/dashes into underscores and downcase so "Next Appointment"
    # and "next-appointment" both collide with "next_appointment".
    def normalize_alias(str)
      return nil if str.nil?
      str.to_s.strip.downcase.gsub(/[\s\-]+/, '_')
    end

    # Return the canonical field_key for a candidate, or nil if the entity has
    # no custom field matching that alias.
    def resolve_field_key(entity, candidate)
      alias_map(entity)[normalize_alias(candidate)]
    end

    # Split an attributes hash into { real:, custom: } so callers can
    # `entity.update!(real)` and merge `custom` into `custom_field_values`.
    # Custom-side keys are always the canonical field_key even if the caller
    # passed a display-name alias.
    def partition(entity, attrs)
      return { real: attrs.dup, custom: {} } unless supports_custom_fields?(entity)

      real = {}
      custom = {}
      attrs.each do |k, v|
        canonical = resolve_field_key(entity, k)
        if canonical
          custom[canonical] = v
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

    # Look up a single custom field value for an entity by field_key OR any
    # accepted alias (display name, normalized form).
    def read(entity, key)
      return nil unless supports_custom_fields?(entity)

      values = entity.custom_field_values
      return nil if values.blank?

      canonical = resolve_field_key(entity, key)
      lookup = canonical || key.to_s
      values[lookup] || values[lookup.to_sym]
    end
  end
end
