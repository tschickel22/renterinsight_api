# frozen_string_literal: true

module Guide
  # Records a batch of usage events from the browser and folds them into the
  # per-person rollup in the same request.
  #
  # Feature keys are Atlas keys ("report:profit-and-loss", "page:/deals",
  # "setting:users") for page views and data-tour markers for clicks. They are
  # checked for shape, never trusted as anything more than a label.
  class UsageRecorder
    MAX_EVENTS = 50
    KEY_FORMAT = %r{\A[a-z][a-z0-9_-]*(:[\w/.:?=&-]+)?\z}i
    MAX_KEY = 200

    def initialize(user:, company_id:)
      @user = user
      @company_id = company_id
    end

    # events: [{ 'kind' => 'page', 'feature' => 'report:profit-and-loss', 'route' => '/accounting/...', 'at' => iso8601 }]
    # Returns how many were recorded.
    def record(events)
      now = Time.current
      rows = Array(events).first(MAX_EVENTS).filter_map { |e| row_for(e, now) }
      return 0 if rows.empty?

      GuideEvent.insert_all(rows)
      roll_up(rows, now)
      rows.size
    end

    private

    def row_for(event, now)
      e = event.respond_to?(:to_unsafe_h) ? event.to_unsafe_h : event.to_h
      kind = e['kind'].to_s
      key = e['feature'].to_s.strip
      return unless GuideEvent::KINDS.include?(kind)
      return if key.empty? || key.length > MAX_KEY || !key.match?(KEY_FORMAT)

      {
        company_id: @company_id,
        user_id: @user.id,
        kind: kind,
        feature_key: key,
        route: e['route'].to_s.first(500).presence,
        occurred_at: parse_time(e['at'], now),
        created_at: now
      }
    end

    # Clamp to the last day: a browser clock can be anywhere.
    def parse_time(value, now)
      t = Time.zone.parse(value.to_s) rescue nil
      t && t <= now && t > now - 1.day ? t : now
    end

    def roll_up(rows, now)
      grouped = rows.group_by { |r| r[:feature_key] }
      values = grouped.map do |key, rs|
        times = rs.map { |r| r[:occurred_at] }
        [@company_id, @user.id, key, times.min, times.max, rs.size, now, now]
      end

      placeholders = (['(?, ?, ?, ?, ?, ?, ?, ?)'] * values.size).join(', ')
      sql = <<~SQL
        INSERT INTO guide_feature_usages
          (company_id, user_id, feature_key, first_used_at, last_used_at, use_count, created_at, updated_at)
        VALUES #{placeholders}
        ON CONFLICT (user_id, feature_key) DO UPDATE SET
          first_used_at = LEAST(guide_feature_usages.first_used_at, EXCLUDED.first_used_at),
          last_used_at  = GREATEST(guide_feature_usages.last_used_at, EXCLUDED.last_used_at),
          use_count     = guide_feature_usages.use_count + EXCLUDED.use_count,
          updated_at    = EXCLUDED.updated_at
      SQL
      ActiveRecord::Base.connection.exec_update(
        ActiveRecord::Base.sanitize_sql_array([sql, *values.flatten])
      )
    end
  end
end
