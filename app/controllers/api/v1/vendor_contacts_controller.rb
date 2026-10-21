# frozen_string_literal: true

# The people at a vendor, and which of them get project emails and texts.
# Contractors are vendors too, so a contractor's contacts are checked against the
# contractors permission and everyone else's against vendors.
class Api::V1::VendorContactsController < ApplicationController
  before_action :set_company_scope
  before_action :set_vendor
  before_action :set_contact, only: [:update, :destroy, :sms_consent]

  def index
    return unless authorize_action!(resource_key, 'read')

    render json: { items: @vendor.vendor_contacts.map { |c| self.class.contact_json(c) } }
  end

  def create
    return unless authorize_action!(resource_key, 'update')

    contact = @vendor.vendor_contacts.build(contact_params.merge(company_id: @company.id))
    if contact.save
      render json: self.class.contact_json(contact), status: :created
    else
      render json: { errors: contact.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def update
    return unless authorize_action!(resource_key, 'update')

    if @contact.update(contact_params)
      render json: self.class.contact_json(@contact)
    else
      render json: { errors: @contact.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def destroy
    return unless authorize_action!(resource_key, 'update')

    @contact.soft_delete!
    head :no_content
  end

  # POST /api/v1/vendors/:vendor_id/contacts/:id/sms-consent
  # Same rules as the contractor's own consent: granting needs a phone and a
  # note saying how consent was given; revoking needs neither.
  def sms_consent
    return unless authorize_action!(resource_key, 'update')

    opted_in = ActiveModel::Type::Boolean.new.cast(params[:opted_in])
    if opted_in && @contact.phone.blank?
      return render json: { error: 'Add a phone number before recording SMS consent' }, status: :unprocessable_entity
    end
    if opted_in && params[:note].blank?
      return render json: { error: 'Describe how they gave consent' }, status: :unprocessable_entity
    end

    @contact.record_sms_consent!(opted_in: opted_in, source: opted_in ? 'dealer_recorded' : nil,
                                 user: current_user, note: params[:note])
    render json: self.class.contact_json(@contact.reload)
  end

  def self.contact_json(contact)
    {
      id: contact.id,
      vendorId: contact.vendor_id,
      firstName: contact.first_name,
      lastName: contact.last_name,
      name: contact.name,
      title: contact.title,
      email: contact.email,
      phone: contact.phone,
      priority: contact.priority,
      notes: contact.notes,
      isPrimary: contact.is_primary,
      receivesProjectNotices: contact.receives_project_notices,
      smsOptIn: contact.sms_opt_in,
      canReceiveSms: contact.can_receive_sms?,
      smsConsentSource: contact.sms_consent_source,
      smsConsentRecordedAt: contact.sms_consent_recorded_at,
      smsConsentNote: contact.sms_consent_note,
      createdAt: contact.created_at,
      updatedAt: contact.updated_at
    }
  end

  private

  def resource_key
    @vendor.contractor? ? 'contractors' : 'vendors'
  end

  def set_vendor
    @vendor = @company.vendors.where(is_deleted: [false, nil]).find(params[:vendor_id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Vendor not found' }, status: :not_found
  end

  def set_contact
    @contact = @vendor.vendor_contacts.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Contact not found' }, status: :not_found
  end

  # SMS consent is not editable here; it goes through sms_consent so it always
  # carries who recorded it and how.
  def contact_params
    params.require(:contact).permit(:first_name, :last_name, :title, :email, :phone, :priority, :notes,
                                    :is_primary, :receives_project_notices)
  end
end
