# frozen_string_literal: true

module Api
  module V1
    # The signed-in person's saved list filters for the current company, so the
    # lead, contact, account and deal lists open on what they used last instead
    # of resetting to "mine" every login (admins who sell had to clear it every
    # time). The browser keeps filters for the session; this carries them across
    # logins and devices. Search text is not saved.
    #
    # GET /api/v1/me/list-filters        -> { filters: { leads: {...}, ... } }
    # PUT /api/v1/me/list-filters        { list: 'leads', values: {...} }
    #
    # Impersonating: reads work, saves are skipped, so looking at a rep's screen
    # never rewrites their filters.
    class ListFiltersController < ApplicationController
      before_action :set_company_scope

      LISTS = %w[leads contacts accounts deals].freeze
      MAX_KEYS = 40
      MAX_VALUE = 1000

      def show
        render json: { filters: company_prefs(current_user) }
      end

      def update
        list = params[:list].to_s
        return render(json: { error: 'Unknown list' }, status: :bad_request) unless LISTS.include?(list)
        return render(json: { ok: true, saved: false }) if impersonating?

        values = sanitize(params[:values])
        user = current_user
        user.with_lock do
          all = (user.list_filter_preferences || {}).deep_dup
          mine = (all[@company.id.to_s] ||= {})
          mine[list] = values
          user.update_columns(list_filter_preferences: all, updated_at: Time.current)
        end
        render json: { ok: true, saved: true }
      end

      private

      def company_prefs(user)
        (user.list_filter_preferences || {})[@company.id.to_s] || {}
      end

      # Flat map of filter name to a string, number, boolean or null. Anything
      # else (nested objects, huge strings) is dropped rather than stored.
      def sanitize(raw)
        hash = raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : (raw.is_a?(Hash) ? raw : {})
        hash.first(MAX_KEYS).each_with_object({}) do |(k, v), out|
          key = k.to_s
          next if key.blank? || key.length > 60 || key == 'search'

          case v
          when String then out[key] = v[0, MAX_VALUE]
          when Numeric, TrueClass, FalseClass, NilClass then out[key] = v
          end
        end
      end
    end
  end
end
