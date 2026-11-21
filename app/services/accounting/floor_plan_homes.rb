# frozen_string_literal: true

module Accounting
  # One place to see and set up which homes are on floor plan (2026-11-20).
  #
  # A home builds up floor plan interest only when its own record carries an
  # amount, a rate and a start date. Turning tracking on in Accounting Settings
  # never put a home on it, so a dealer had no view of the in-stock homes that
  # were missing and no way to start them except one edit form at a time. This
  # lists both groups, flags homes that are set up halfway (they accrue $0 and
  # nothing said so), and writes the same fields the home's own Floor Plan
  # section does, so the two places always agree.
  class FloorPlanHomes
    # Homes the dealer holds and could be paying a lender on. Sold homes are
    # paid off; order statuses are not on the lot yet; trade-ins are owned
    # outright.
    IN_STOCK = %w[available reserved pending service].freeze

    Result = Struct.new(:ok, :vehicle, :error, keyword_init: true)

    def initialize(company, scope: nil)
      @company = company
      @scope = scope || company.vehicles
      @settings = AccountingSettings.for_company(company)
    end

    def self.tracked_scope(vehicles)
      scope = vehicles.where(is_deleted: false).where('floor_plan_amount > 0').where(floor_plan_curtailed_at: nil)
      scope.where.not(status: %w[sold delivered])
    end

    def defaults
      {
        tracking_enabled: @settings.floor_plan_tracking_enabled,
        rate: @settings.default_floor_plan_rate&.to_f,
        lender: @settings.default_floor_plan_lender.presence
      }
    end

    def overview
      tracked = self.class.tracked_scope(@scope).order(:floor_plan_start_date, :id).to_a
      untracked = untracked_scope.order(:created_at, :id).to_a
      tracked_rows = tracked.map { |v| tracked_json(v) }

      {
        defaults: defaults,
        tracked: tracked_rows,
        untracked: untracked.map { |v| untracked_json(v) },
        summary: {
          tracked_count: tracked_rows.size,
          untracked_count: untracked.size,
          needs_setup_count: tracked_rows.count { |r| r[:problems].any? },
          total_principal: tracked_rows.sum { |r| r[:principal] }.round(2),
          total_accrued_interest: tracked_rows.sum { |r| r[:accrued_interest] }.round(2)
        }
      }
    end

    def summary
      tracked = self.class.tracked_scope(@scope)
      {
        tracked_count: tracked.count,
        untracked_count: untracked_scope.count,
        needs_setup_count: tracked.where('floor_plan_rate IS NULL OR floor_plan_rate <= 0 OR floor_plan_start_date IS NULL').count
      }
    end

    # Starts tracking, or changes a tracked home. Blank rate and lender take
    # the company defaults; a blank start date is today.
    def save(vehicle, attrs)
      attrs = (attrs || {}).to_h.symbolize_keys
      amount = decimal(attrs[:amount])
      rate = attrs.key?(:rate) && attrs[:rate].to_s.strip != '' ? decimal(attrs[:rate]) : (vehicle.floor_plan_rate.presence || @settings.default_floor_plan_rate)
      lender = attrs.key?(:lender) ? attrs[:lender].to_s.strip.presence : vehicle.floor_plan_lender
      lender ||= @settings.default_floor_plan_lender.presence
      start = attrs[:start_date].present? ? parse_date(attrs[:start_date]) : (vehicle.floor_plan_start_date || Date.current)

      return failure(vehicle, 'Enter the amount the lender advanced on this home.') unless amount&.positive?
      return failure(vehicle, 'Enter the yearly interest rate the lender charges.') unless rate&.positive?
      return failure(vehicle, 'The rate looks wrong. Enter it as a yearly percent, like 8.5.') if rate >= 100
      return failure(vehicle, 'Enter the start date as a date.') unless start
      return failure(vehicle, 'The start date cannot be in the future.') if start > Date.current
      return failure(vehicle, 'This home was paid off on its floor plan. Its payoff stays as it is.') if vehicle.floor_plan_curtailed_at.present?

      vehicle.update!(floor_plan_amount: amount, floor_plan_rate: rate, floor_plan_lender: lender, floor_plan_start_date: start)
      Result.new(ok: true, vehicle: vehicle)
    rescue ActiveRecord::RecordInvalid => e
      failure(vehicle, e.record.errors.full_messages.to_sentence)
    end

    # Takes a home off floor plan without recording a payoff (it was put on by
    # mistake, or the dealer paid cash). Interest already posted stays in the
    # books; the rate and lender stay so starting again is one click.
    def stop(vehicle)
      return failure(vehicle, 'This home is not on floor plan.') unless vehicle.floor_plan_amount.to_f.positive?

      vehicle.update!(floor_plan_amount: nil, floor_plan_start_date: nil)
      Result.new(ok: true, vehicle: vehicle)
    end

    private

    def untracked_scope
      @scope.where(is_deleted: false, status: IN_STOCK)
            .where('floor_plan_amount IS NULL OR floor_plan_amount <= 0')
            .where(floor_plan_curtailed_at: nil)
    end

    def base_json(vehicle)
      {
        vehicle_id: vehicle.id,
        stock_number: vehicle.stock_number,
        year: vehicle.year,
        make: vehicle.make,
        model: vehicle.model,
        serial_number: vehicle.try(:serial_number),
        vin: vehicle.try(:vin),
        status: vehicle.status,
        location_id: vehicle.location_id
      }
    end

    def tracked_json(vehicle)
      principal = vehicle.floor_plan_amount.to_f
      rate = vehicle.floor_plan_rate.to_f
      start = vehicle.floor_plan_start_date
      problems = []
      problems << 'no_rate' unless rate.positive?
      problems << 'no_start_date' if start.blank?

      base_json(vehicle).merge(
        principal: principal.round(2),
        rate: rate.positive? ? rate : nil,
        lender: vehicle.floor_plan_lender,
        start_date: start,
        days_on_plan: start ? [(Date.current - start).to_i, 0].max : 0,
        accrued_interest: vehicle.floor_plan_accrued_interest.to_f.round(2),
        monthly_interest_estimate: (principal * rate / 100.0 / 365.0 * 30).round(2),
        problems: problems
      )
    end

    def untracked_json(vehicle)
      base_json(vehicle).merge(
        suggested_amount: vehicle.structured_cost,
        # When the home came in is usually when the lender started charging.
        suggested_start_date: [vehicle.date_in_stock&.to_date, Date.current].compact.min,
        in_stock_since: vehicle.date_in_stock&.to_date,
        added_on: vehicle.created_at&.to_date
      )
    end

    def decimal(value)
      return nil if value.nil? || value.to_s.strip == ''

      BigDecimal(value.to_s.delete(',$% '))
    rescue ArgumentError
      nil
    end

    def parse_date(value)
      Date.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end

    def failure(vehicle, message)
      Result.new(ok: false, vehicle: vehicle, error: message)
    end
  end
end
