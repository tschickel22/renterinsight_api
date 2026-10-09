# frozen_string_literal: true

# A lead form's definition, for drawing it on a dealer's website.
#
# Sites embed forms (the contact section, the inquiry button on a listing),
# and the embed used to read /api/crm/intake/forms/:id with the public
# inventory token. That path is the staff API, which a dealer's own hostname
# may not read cross-origin, so on a published site the browser discarded the
# answer and the form showed "Failed to fetch". It only ever worked where the
# site was rendered on an allowlisted host (the preview). This lives under
# /public/*, which tenant hostnames can read, and answers with the visitor's
# view of the form only.
#
# Authorised the same way as the inventory feed: the company's public
# inventory token, with the company named alongside it.
class Public::IntakeFormsController < ApplicationController
  skip_before_action :authenticate, raise: false
  skip_before_action :set_company_scope, raise: false
  skip_before_action :set_current_attributes, raise: false
  skip_before_action :check_rbac_authorization, raise: false

  # GET /public/intake_forms/:id?token=...&company_id=...
  def show
    company = Company.find_by(id: params[:company_id])
    token = params[:token].to_s
    if company.nil? || token.blank? || company.public_inventory_token.blank? ||
       !ActiveSupport::SecurityUtils.secure_compare(company.public_inventory_token, token)
      return render json: { error: 'Invalid token' }, status: :unauthorized
    end

    form = company.intake_forms.find_by(id: params[:id], is_active: true)
    return render json: { error: 'Form not found' }, status: :not_found unless form

    response = form.public_as_json
    # The "which location is closest to you?" picker, when the form is not
    # bound to a location and there is more than one to choose from.
    if form.location_id.blank?
      locations = company.locations.active.order(:name)
      if locations.count > 1
        response['company_locations'] = locations.map { |l| { id: l.id, name: l.name, city: l.city, state: l.state } }
      end
    end

    render json: response
  end
end
