# frozen_string_literal: true

module McpTools
  # Turns "2026-10-06T10:00" from the AI into a real moment, in the dealer's
  # time zone, and says which zone it used so the reply can tell the person.
  #
  # The app itself has no per-user time zone: the activity forms send the
  # browser's local time, and server-side code (campaign send windows,
  # LocationSettingsResolver) reads the location's `timezone` column first,
  # then the company's operational setting, then Eastern. The connector has no
  # browser, so it follows the server-side order:
  #
  #   1. the record's location (a lead's location for a lead follow-up)
  #   2. the signed-in person's own location, when they work at one
  #   3. the company's operational time zone setting
  #   4. Eastern, the app's default
  #
  # locations.timezone defaults to America/New_York at the database level, so
  # a location that nobody set up reads as Eastern wherever it is (every
  # Summit Park location on staging, in Colorado, did in 2026-10). The zone is
  # still the one the app uses, so the connector uses it too, but it warns
  # when the zone does not fit the location's state, so the AI can raise it.
  module LocalTime
    DEFAULT_ZONE = 'America/New_York'
    DATE_ONLY = /\A\d{4}-\d{2}-\d{2}\z/
    END_OF_DAY = '17:00'

    Zone = Struct.new(:zone, :source, :warning, keyword_init: true) do
      def name
        zone.tzinfo.name
      end

      # Fields every reply that schedules something carries.
      def describe
        { time_zone: name, time_zone_source: source, time_zone_warning: warning }.compact
      end
    end

    # The zones a state's dealers can plausibly be in. Several states span
    # two zones; a zone matches when its offsets match any of these.
    STATE_ZONES = {
      'America/New_York' => %w[CT DC DE GA MA MD ME NC NH NJ NY OH PA RI SC VA VT WV FL IN KY MI TN],
      'America/Chicago' => %w[AL AR IA IL LA MN MO MS OK WI KS NE ND SD TX FL IN KY MI TN],
      'America/Denver' => %w[CO MT NM UT WY ID KS NE ND SD TX OR],
      'America/Phoenix' => %w[AZ],
      'America/Los_Angeles' => %w[CA NV WA ID OR],
      'America/Anchorage' => %w[AK],
      'Pacific/Honolulu' => %w[HI]
    }.each_with_object({}) { |(zone, states), map| states.each { |s| (map[s] ||= []) << zone } }.freeze

    module_function

    def resolve(ctx, location_id: nil)
      if (zone = location_zone(ctx, location_id, 'location'))
        return zone
      end
      if (zone = location_zone(ctx, own_location_id(ctx, location_id), 'your location'))
        return zone
      end

      setting = ctx.company.operational_settings['timezone'].presence
      if setting && (tz = ActiveSupport::TimeZone[setting])
        return Zone.new(zone: tz, source: 'company time zone setting')
      end

      Zone.new(zone: ActiveSupport::TimeZone[DEFAULT_ZONE],
               source: 'default (no location or company time zone set)',
               warning: 'No time zone is set for this location or company, so Eastern time was used. ' \
                        'Check the time with the person.')
    end

    # Returns [time, zone]. A date alone means the end of that day locally.
    def parse!(ctx, value, location_id: nil)
      zone = resolve(ctx, location_id: location_id)
      text = value.to_s.strip
      time = text.match?(DATE_ONLY) ? zone.zone.parse("#{text} #{END_OF_DAY}") : zone.zone.parse(text)
      raise UserError, 'due_date must look like 2026-10-02 or 2026-10-02T15:00.' unless time

      [time, zone]
    rescue ArgumentError
      raise UserError, 'due_date must look like 2026-10-02 or 2026-10-02T15:00.'
    end

    # "2026-10-06T10:00:00-06:00": the dealer's wall clock with its offset,
    # rather than UTC, so the AI repeats the time the person asked for.
    def iso(time, zone)
      time&.in_time_zone(zone.zone)&.iso8601
    end

    def location_zone(ctx, location_id, label)
      return nil if location_id.blank?

      name, tz_name, state = ctx.company.locations.where(id: location_id).pick(:name, :timezone, :state)
      tz = tz_name.presence && ActiveSupport::TimeZone[tz_name]
      return nil unless tz

      Zone.new(zone: tz, source: "#{label} #{name}".strip, warning: mismatch_warning(name, tz, state))
    end

    # The person's own location, used when the record has none. Company-wide
    # roles have no single location, so this is nil for them.
    def own_location_id(ctx, record_location_id)
      return nil if record_location_id.present?

      ctx.default_location_id
    end

    def mismatch_warning(location_name, tz, state)
      code = state.to_s.strip.upcase
      candidates = STATE_ZONES.fetch(code, [])
      return nil if candidates.empty?
      return nil if candidates.any? { |c| same_offsets?(ActiveSupport::TimeZone[c], tz) }

      "#{location_name} is in #{code} but its time zone is set to #{tz.tzinfo.name}. The time was read in " \
        "#{tz.tzinfo.name} because that is what DealerTide uses for this location. Confirm the time with the " \
        "person, and the time zone can be corrected in Settings, Locations."
    end

    def same_offsets?(a, b)
      year = Time.current.year
      [Time.utc(year, 1, 15), Time.utc(year, 7, 15)].all? { |t| t.in_time_zone(a).utc_offset == t.in_time_zone(b).utc_offset }
    end
  end
end
