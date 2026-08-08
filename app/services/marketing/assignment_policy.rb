# frozen_string_literal: true

module Marketing
  # Who a visitor gets put in front of, decided by the dealer rather than by us.
  #
  # A fixed waterfall was wrong. Some dealers want every enquiry going to one
  # dealership calendar, some want the rep who owns the relationship, and some
  # want it spread across a team. Those are business decisions and the dealer is
  # the only one who knows which they are, so the precedence is configuration,
  # not code.
  #
  # Deliberately shared. The booking link asks "whose calendar", and the Text Us
  # widget will ask "whose phone", but both are the same question: which person
  # does this visitor belong to. Building one policy now means the two cannot
  # answer it differently later, which is exactly the drift that makes a dealer
  # distrust both.
  #
  # Stored per company under the operational settings a dealer already edits, and
  # optionally overridden per location, since a multi-lot dealer routinely runs
  # one lot differently from another.
  class AssignmentPolicy
    # dealership   one shared calendar or number, nobody in particular
    # user         one named person
    # round_robin  spread across a list, using the existing atomic cursor
    # assigned_rep whoever already owns the relationship, falling back to the
    #              dealership when nobody does
    MODES = %w[dealership user round_robin assigned_rep].freeze
    DEFAULT_MODE = 'dealership'

    Resolution = Struct.new(:mode, :user, keyword_init: true)

    def initialize(company:, location: nil, feature: 'booking')
      @company = company
      @location = location
      @feature = feature
    end

    # @param fallback_user [User, nil] whoever already owns the conversation
    # @return [Resolution]
    def resolve(fallback_user: nil)
      case mode
      when 'user' then Resolution.new(mode: 'user', user: configured_user)
      when 'round_robin' then Resolution.new(mode: 'round_robin', user: next_in_rotation)
      when 'assigned_rep' then Resolution.new(mode: 'assigned_rep', user: fallback_user)
      else Resolution.new(mode: 'dealership', user: nil)
      end
    end

    def mode
      value = config['mode'].to_s
      MODES.include?(value) ? value : DEFAULT_MODE
    end

    private

    # Location first, so a multi-lot dealer can run one lot differently, then the
    # company. Both key spellings are read at the location scope because the
    # settings UI writes one and LocationSettingsResolver reads the other.
    def config
      @config ||= location_config.presence || company_config.presence || {}
    end

    def location_config
      return {} if @location.nil?

      %w[operational operational_settings].each do |key|
        value = Setting.get('Location', @location.id, key).to_h.dig("#{@feature}_assignment")
        return value.to_h if value.present?
      end
      {}
    rescue StandardError
      {}
    end

    def company_config
      return {} if @company.nil?

      %w[operational_settings operational].each do |key|
        value = Setting.get('Company', @company.id, key).to_h.dig("#{@feature}_assignment")
        return value.to_h if value.present?
      end
      {}
    rescue StandardError
      {}
    end

    def configured_user
      id = config['user_id']
      return nil if id.blank?

      @company&.users&.find_by(id: id)
    rescue StandardError
      nil
    end

    # A separate list per feature on purpose: a booking rotation sharing a cursor
    # with the text queue would advance one every time the other was used, and
    # neither would be a fair rotation.
    def next_in_rotation
      id = config['round_robin_list_id']
      return nil if id.blank?

      # Queried directly: Company has no association for these, and scoping by
      # company_id here is what keeps one dealer's rotation out of another's.
      list = RoundRobinAssignmentList.find_by(id: id, company_id: @company&.id, active: true)
      list&.next_active_user!
    rescue StandardError => e
      Rails.logger.warn("[AssignmentPolicy] rotation failed for company #{@company&.id}: #{e.message}")
      nil
    end
  end
end
