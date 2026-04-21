# frozen_string_literal: true

# Reads / writes the 'social_media_notifications' Setting with a
# Location → Company → Defaults waterfall. Matches the convention used by
# the existing CommunicationSettingsService.
class SocialMediaSettingsService
  SETTING_KEY = 'social_media_notifications'

  DEFAULTS = {
    'comment_notification_users' => [],
    'email_on_comments'          => true,
    'push_on_comments'           => true,
    'notify_post_creator'        => true,
    'auto_hide_profanity'        => false,
    'comment_sync_enabled'       => true
  }.freeze

  class << self
    def for_company(company, location_id: nil)
      result = DEFAULTS.dup
      result.merge!(normalize(Setting.get('Company', company.id, SETTING_KEY)))
      if location_id.present?
        result.merge!(normalize(Setting.get('Location', location_id, SETTING_KEY)))
      end
      result
    end

    def update(scope_type:, scope_id:, attrs:)
      stored = normalize(Setting.get(scope_type, scope_id, SETTING_KEY))
      merged = stored.merge(sanitize(attrs))
      Setting.set(scope_type, scope_id, SETTING_KEY, merged)
      merged
    end

    private

    def normalize(value)
      case value
      when Hash   then value.deep_stringify_keys
      when String then (JSON.parse(value).deep_stringify_keys rescue {})
      else              {}
      end
    end

    def sanitize(attrs)
      hash = attrs.is_a?(Hash) ? attrs.deep_stringify_keys : {}
      hash.slice(*DEFAULTS.keys).tap do |h|
        h['comment_notification_users'] = Array(h['comment_notification_users']).map(&:to_i).uniq if h.key?('comment_notification_users')
        %w[email_on_comments push_on_comments notify_post_creator auto_hide_profanity comment_sync_enabled].each do |k|
          h[k] = ActiveModel::Type::Boolean.new.cast(h[k]) if h.key?(k)
        end
      end
    end
  end
end
