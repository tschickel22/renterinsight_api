# frozen_string_literal: true

module Api
  module V1
    # Resolves a deep-linked record to the company and location it lives in, so
    # the app can put the user in the right context instead of asking them to
    # guess it.
    #
    # A lead alert email drops someone straight on /crm/leads/19625. If they
    # have no location in session the app blocks the page and makes them pick
    # one from a dropdown, and a dealer with several rooftops has no way of
    # knowing which one that lead belongs to. Picking wrong used to strand them
    # somewhere the record was not.
    #
    # Returns only the identifiers needed to select context. Nothing about the
    # record itself is exposed here, and opening it still runs the record's own
    # authorization.
    class DeepLinksController < ApplicationController
      before_action :set_company_scope

      # Deep-link types the app can route to, mapped to their model and the
      # permission resource that governs reading one. Only records that carry a
      # location_id can be resolved; page types without one (properties, units,
      # leases) are absent on purpose rather than silently returning nothing.
      #
      # The resource keys are NOT the model names. They are whatever the
      # controller that serves the record already checks, because a key with no
      # row in `resources` denies every RBAC user and the feature would simply
      # stop working for them with no visible error. Contacts and accounts sit
      # under 'crm', quotes and payments under 'finance', tickets under
      # 'service'. Verify against the owning controller before adding a type.
      RESOLVABLE_TYPES = {
        'lead'    => { model: 'Lead',          resource: 'leads' },
        'contact' => { model: 'Contact',       resource: 'crm' },
        'account' => { model: 'Account',       resource: 'crm' },
        'quote'   => { model: 'Quote',         resource: 'finance' },
        'deal'    => { model: 'Deal',          resource: 'deals' },
        'invoice' => { model: 'Invoice',       resource: 'invoices' },
        'payment' => { model: 'Payment',       resource: 'finance' },
        'ticket'  => { model: 'ServiceTicket', resource: 'service' }
      }.freeze

      # GET /api/v1/deep_links/resolve?type=lead&id=19625
      def resolve
        mapping = RESOLVABLE_TYPES[params[:type].to_s]
        return render(json: { error: 'Unsupported type' }, status: :bad_request) if mapping.nil?

        return unless authorize_action!(mapping[:resource], 'read')

        record = find_record(mapping[:model])
        return render(json: { error: 'Not found' }, status: :not_found) if record.nil?

        location = Location.find_by(id: record.location_id)

        render json: {
          companyId: record.company_id,
          locationId: record.location_id,
          locationName: location&.name
        }
      end

      private

      # Tenant isolation is the whole security story for this endpoint, so the
      # lookup is scoped to the caller's company. Platform admins resolve across
      # companies because for them the record also determines which tenant to
      # switch into, which is the same problem one level up.
      def find_record(model_name)
        klass = model_name.constantize

        if current_user.platform_admin? || current_user.super_admin?
          klass.find_by(id: params[:id])
        else
          klass.where(company_id: @company.id).find_by(id: params[:id])
        end
      end
    end
  end
end
