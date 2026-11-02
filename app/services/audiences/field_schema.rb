module Audiences
  module FieldSchema
    # Address fields. States are stored as two-letter codes ("CO"); a zip
    # prefix ("802") reaches an area. Matching ignores case and surrounding
    # spaces (see FilterCompiler::CASE_INSENSITIVE_FIELDS).
    STATE_OPS = %w[equals not_equals in not_in is_set is_blank].freeze
    CITY_OPS  = %w[equals not_equals contains in not_in is_set is_blank].freeze
    ZIP_OPS   = %w[equals starts_with in not_in is_set is_blank].freeze

    def self.address_fields(city:, state:, zip:, label_prefix: nil, street: nil)
      prefix = label_prefix ? "#{label_prefix} " : ''
      group = label_prefix ? "#{label_prefix} address" : 'Address'
      fields = []
      fields << { key: street, label: "#{prefix}Street".strip.capitalize, group: group, type: 'string', operators: %w[contains is_set is_blank] } if street
      fields + [
        { key: city,  label: "#{prefix}city".capitalize,  group: group, type: 'string', operators: CITY_OPS },
        { key: state, label: "#{prefix}state".capitalize, group: group, type: 'string', operators: STATE_OPS },
        { key: zip,   label: "#{prefix}zip".capitalize,   group: group, type: 'string', operators: ZIP_OPS }
      ]
    end

    LEAD_FIELDS = [
      { key: 'first_name', label: 'First name', group: 'Personal', type: 'string', operators: %w[equals not_equals contains starts_with is_set is_blank] },
      { key: 'last_name', label: 'Last name', group: 'Personal', type: 'string', operators: %w[equals not_equals contains starts_with is_set is_blank] },
      { key: 'email', label: 'Email', group: 'Personal', type: 'string', operators: %w[equals contains is_set is_blank] },
      { key: 'phone', label: 'Phone', group: 'Personal', type: 'string', operators: %w[equals contains is_set is_blank] },
      { key: 'company_name', label: 'Company name', group: 'Personal', type: 'string', operators: %w[equals not_equals contains not_contains starts_with is_set is_blank] },
      { key: 'title', label: 'Job title', group: 'Personal', type: 'string', operators: %w[equals not_equals contains starts_with is_set is_blank] },
      { key: 'status', label: 'Status', group: 'Lead', type: 'select', operators: %w[equals not_equals in not_in], options: %w[new contacted qualified proposal disqualified converted] },
      { key: 'source_name', label: 'Lead source', group: 'Lead', type: 'string', operators: %w[equals not_equals contains in not_in is_set is_blank] },
      { key: 'owner_name', label: 'Assigned to', group: 'Lead', type: 'string', operators: %w[equals not_equals contains is_set is_blank] },
      { key: 'location_id', label: 'Location', group: 'Lead', type: 'number', operators: %w[equals not_equals in not_in is_set is_blank] },
      { key: 'health_score', label: 'Lead score', group: 'Lead', type: 'number', operators: %w[equals greater_than less_than greater_than_or_equal less_than_or_equal] },
      *address_fields(city: 'city', state: 'state', zip: 'zip'),
      { key: 'opt_in_sms', label: 'SMS opt-in', group: 'Compliance', type: 'boolean', operators: %w[equals] },
      { key: 'last_activity_at', label: 'Last activity at', group: 'Activity', type: 'date', operators: %w[days_since_greater_than is_set is_blank] },
      { key: 'created_at', label: 'Created at', group: 'Activity', type: 'date', operators: %w[days_since_greater_than greater_than less_than] },
      { key: 'tags', label: 'Tags', group: 'Tags', type: 'tags', operators: %w[tags_include tags_exclude tags_any_of] }
    ].freeze

    CONTACT_FIELDS = [
      { key: 'first_name', label: 'First name', group: 'Personal', type: 'string', operators: %w[equals not_equals contains starts_with is_set is_blank] },
      { key: 'last_name', label: 'Last name', group: 'Personal', type: 'string', operators: %w[equals not_equals contains starts_with is_set is_blank] },
      { key: 'email', label: 'Email', group: 'Personal', type: 'string', operators: %w[equals contains is_set is_blank] },
      { key: 'phone', label: 'Phone', group: 'Personal', type: 'string', operators: %w[equals contains is_set is_blank] },
      { key: 'company_name', label: 'Company name', group: 'Personal', type: 'string', operators: %w[equals not_equals contains not_contains starts_with is_set is_blank] },
      { key: 'title', label: 'Job title', group: 'Personal', type: 'string', operators: %w[equals not_equals contains starts_with is_set is_blank] },
      { key: 'location_id', label: 'Location', group: 'Account', type: 'number', operators: %w[equals not_equals in not_in is_set is_blank] },
      *address_fields(street: 'street', city: 'city', state: 'state', zip: 'zip'),
      { key: 'opt_in_sms', label: 'SMS opt-in', group: 'Compliance', type: 'boolean', operators: %w[equals] },
      { key: 'account_id', label: 'Linked account', group: 'Account', type: 'number', operators: %w[equals not_equals is_set is_blank] },
      { key: 'created_at', label: 'Created at', group: 'Activity', type: 'date', operators: %w[days_since_greater_than greater_than less_than] },
      { key: 'tags', label: 'Tags', group: 'Tags', type: 'tags', operators: %w[tags_include tags_exclude tags_any_of] }
    ].freeze

    ACCOUNT_FIELDS = [
      { key: 'name', label: 'Name', group: 'Account', type: 'string', operators: %w[equals not_equals contains starts_with is_set is_blank] },
      { key: 'account_type', label: 'Account type', group: 'Account', type: 'select', operators: %w[equals not_equals in not_in], options: %w[customer prospect partner vendor] },
      { key: 'website', label: 'Website', group: 'Account', type: 'string', operators: %w[contains is_set is_blank] },
      *address_fields(label_prefix: 'Billing', street: 'billing_street', city: 'billing_city', state: 'billing_state', zip: 'billing_postal_code'),
      *address_fields(label_prefix: 'Shipping', street: 'shipping_street', city: 'shipping_city', state: 'shipping_state', zip: 'shipping_postal_code'),
      { key: 'created_at', label: 'Created at', group: 'Activity', type: 'date', operators: %w[days_since_greater_than greater_than less_than] },
      { key: 'tags', label: 'Tags', group: 'Tags', type: 'tags', operators: %w[tags_include tags_exclude tags_any_of] }
    ].freeze

    OPERATOR_LABELS = {
      'equals' => 'is',
      'not_equals' => 'is not',
      'contains' => 'contains',
      'not_contains' => 'does not contain',
      'starts_with' => 'starts with',
      'ends_with' => 'ends with',
      'greater_than' => '>',
      'less_than' => '<',
      'greater_than_or_equal' => '>=',
      'less_than_or_equal' => '<=',
      'is_set' => 'is set',
      'is_blank' => 'is empty',
      'in' => 'is one of',
      'not_in' => 'is not one of',
      'days_since_greater_than' => 'more than X days ago',
      'tags_include' => 'has tag',
      'tags_exclude' => 'does not have tag',
      'tags_any_of' => 'has any of these tags'
    }.freeze

    # With a company, Lead source becomes a pick list of that company's
    # sources (turned-off ones too, since older leads still carry them), so
    # nobody has to type a source name exactly. 'contains' stays for audiences
    # saved before the list. The company's own custom fields follow the built-in ones.
    def self.for_source_type(source_type, company: nil)
      fields =
        case source_type
        when 'Lead' then LEAD_FIELDS
        when 'Contact' then CONTACT_FIELDS
        when 'Account' then ACCOUNT_FIELDS
        else []
        end
      return fields unless company

      names = nil
      built_in = fields.map do |f|
        next f unless f[:key] == 'source_name'
        names ||= Source.where(company_id: company.id).where.not(name: [nil, '']).distinct.order(:name).pluck(:name)
        names.any? ? f.merge(type: 'select', options: names) : f
      end
      built_in + custom_fields_for(source_type, company)
    end

    # Custom field filters carry this prefix because a dealer's field key can
    # match a built-in one (company 14 has its own "title" and "website").
    CUSTOM_FIELD_PREFIX = 'custom:'
    CUSTOM_FIELD_MODULES = { 'Lead' => 'leads', 'Contact' => 'contacts', 'Account' => 'accounts' }.freeze
    CUSTOM_FIELD_KEY_FORMAT = /\A[\w-]+\z/

    FREE_TEXT_OPS = %w[equals not_equals contains not_contains starts_with is_set is_blank].freeze
    PICK_LIST_OPS = %w[equals not_equals in not_in contains not_contains is_set is_blank].freeze
    # Past this many different values a list is slower than typing.
    PICK_LIST_LIMIT = 100

    def self.custom_field_definitions(source_type, company)
      module_name = CUSTOM_FIELD_MODULES[source_type]
      return CustomField.none unless module_name

      CustomField.where(company_id: company.id, module: module_name)
                 .select { |f| f.field_key.to_s.match?(CUSTOM_FIELD_KEY_FORMAT) }
    end

    def self.custom_fields_for(source_type, company)
      definitions = custom_field_definitions(source_type, company).select(&:is_active)
                                                                  .sort_by { |f| [f.display_order.to_i, f.label.to_s] }
      stored = stored_values(source_type, company, definitions)

      definitions.filter_map do |definition|
        attrs = custom_field_filter(definition, stored[definition.field_key] || [])
        next unless attrs

        { key: "#{CUSTOM_FIELD_PREFIX}#{definition.field_key}", label: definition.label.presence || definition.name,
          group: 'Custom fields' }.merge(attrs)
      end
    end

    # How one custom field filters. nil for the types there is nothing to
    # compare on (a user id, an uploaded file).
    def self.custom_field_filter(definition, stored)
      case definition.field_type
      when 'text', 'select'
        choices = (Array(definition.options).map(&:to_s) + stored).map(&:strip).reject(&:empty?).uniq { |v| v.downcase }
        if choices.any? && choices.length <= PICK_LIST_LIMIT
          { type: 'select', operators: PICK_LIST_OPS, options: choices.sort_by(&:downcase) }
        else
          { type: 'string', operators: FREE_TEXT_OPS }
        end
      when 'multiselect'
        { type: 'select', operators: %w[in not_in is_set is_blank], options: Array(definition.options).map(&:to_s) }
      when 'email', 'phone', 'url'
        { type: 'string', operators: FREE_TEXT_OPS }
      when 'longtext'
        { type: 'string', operators: %w[contains not_contains is_set is_blank] }
      when 'number', 'currency', 'percent'
        { type: 'number', operators: %w[equals greater_than less_than greater_than_or_equal less_than_or_equal is_set is_blank] }
      when 'date', 'datetime'
        { type: 'date', operators: %w[days_since_greater_than greater_than less_than is_set is_blank] }
      when 'checkbox'
        { type: 'boolean', operators: %w[equals] }
      end
    end

    # The values actually on records, so a text field imported from a
    # spreadsheet (company 14's Category) can be picked from a list, and a pick
    # list still offers what an import put there. One query for all the fields.
    def self.stored_values(source_type, company, definitions)
      keys = definitions.select { |f| %w[text select].include?(f.field_type) }.map(&:field_key)
      return {} if keys.empty?

      klass = source_type.constantize
      table = klass.table_name
      klass.where(company_id: company.id)
           .joins("CROSS JOIN LATERAL jsonb_each_text(#{table}.custom_field_values) AS cf(key, value)")
           .where('cf.key IN (?)', keys)
           .where("TRIM(cf.value) <> ''")
           .distinct
           .pluck(Arel.sql('cf.key'), Arel.sql('cf.value'))
           .each_with_object({}) { |(key, value), by_key| (by_key[key] ||= []) << value }
    end

    def self.operators_with_labels
      OPERATOR_LABELS
    end
  end
end
