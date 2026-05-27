module Audiences
  module FieldSchema
    LEAD_FIELDS = [
      { key: 'first_name', label: 'First name', group: 'Personal', type: 'string', operators: %w[equals not_equals contains starts_with is_set is_blank] },
      { key: 'last_name', label: 'Last name', group: 'Personal', type: 'string', operators: %w[equals not_equals contains starts_with is_set is_blank] },
      { key: 'email', label: 'Email', group: 'Personal', type: 'string', operators: %w[equals contains is_set is_blank] },
      { key: 'phone', label: 'Phone', group: 'Personal', type: 'string', operators: %w[equals contains is_set is_blank] },
      { key: 'company_name', label: 'Company name', group: 'Personal', type: 'string', operators: %w[equals not_equals contains not_contains starts_with is_set is_blank] },
      { key: 'title', label: 'Job title', group: 'Personal', type: 'string', operators: %w[equals not_equals contains starts_with is_set is_blank] },
      { key: 'status', label: 'Status', group: 'Lead', type: 'select', operators: %w[equals not_equals in not_in], options: %w[new contacted qualified proposal disqualified converted] },
      { key: 'source', label: 'Source', group: 'Lead', type: 'string', operators: %w[equals not_equals contains in not_in] },
      { key: 'source_name', label: 'Lead source', group: 'Lead', type: 'string', operators: %w[equals not_equals contains in not_in is_set is_blank] },
      { key: 'owner_name', label: 'Assigned to', group: 'Lead', type: 'string', operators: %w[equals not_equals contains is_set is_blank] },
      { key: 'location_id', label: 'Location', group: 'Lead', type: 'number', operators: %w[equals not_equals in not_in is_set is_blank] },
      { key: 'score', label: 'Score', group: 'Lead', type: 'number', operators: %w[equals greater_than less_than greater_than_or_equal less_than_or_equal] },
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
      { key: 'opt_in_sms', label: 'SMS opt-in', group: 'Compliance', type: 'boolean', operators: %w[equals] },
      { key: 'account_id', label: 'Linked account', group: 'Account', type: 'number', operators: %w[equals not_equals is_set is_blank] },
      { key: 'created_at', label: 'Created at', group: 'Activity', type: 'date', operators: %w[days_since_greater_than greater_than less_than] },
      { key: 'tags', label: 'Tags', group: 'Tags', type: 'tags', operators: %w[tags_include tags_exclude tags_any_of] }
    ].freeze

    ACCOUNT_FIELDS = [
      { key: 'name', label: 'Name', group: 'Account', type: 'string', operators: %w[equals not_equals contains starts_with is_set is_blank] },
      { key: 'account_type', label: 'Account type', group: 'Account', type: 'select', operators: %w[equals not_equals in not_in], options: %w[customer prospect partner vendor] },
      { key: 'website', label: 'Website', group: 'Account', type: 'string', operators: %w[contains is_set is_blank] },
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

    def self.for_source_type(source_type)
      case source_type
      when 'Lead' then LEAD_FIELDS
      when 'Contact' then CONTACT_FIELDS
      when 'Account' then ACCOUNT_FIELDS
      else []
      end
    end

    def self.operators_with_labels
      OPERATOR_LABELS
    end
  end
end
