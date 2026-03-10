# frozen_string_literal: true

# Manages co-buyers, guarantors, and cosigners on Deals, Quotes, and Invoices.
# Primary buyer is always the main contact_id on the parent record.
# This controller manages additional buyers via the EntityBuyer join table.
#
# Routes:
#   GET    /api/v1/deals/:deal_id/buyers
#   POST   /api/v1/deals/:deal_id/buyers
#   PATCH  /api/v1/deals/:deal_id/buyers/:id
#   DELETE /api/v1/deals/:deal_id/buyers/:id
#   (same for quotes and invoices)
#
class Api::V1::EntityBuyersController < ApplicationController
  before_action :set_company_scope
  before_action :set_buyable
  before_action :set_entity_buyer, only: [:update, :destroy]

  # GET /api/v1/:entity/:entity_id/buyers
  def index
    return unless authorize_action!(resource_key, 'read')

    buyers = @buyable.entity_buyers.active.ordered.includes(:contact)

    render json: buyers.map { |eb| buyer_json(eb) }
  end

  # POST /api/v1/:entity/:entity_id/buyers
  def create
    return unless authorize_action!(resource_key, 'update')

    contact = @company.contacts.find_by(id: params[:contact_id])
    unless contact
      return render json: { error: 'Contact not found' }, status: :not_found
    end

    # Default role: 'buyer' if first buyer, 'co_buyer' for subsequent
    existing_count = @buyable.entity_buyers.active.count
    default_role = existing_count == 0 ? 'buyer' : 'co_buyer'
    role = params[:role] || default_role

    # Check for soft-deleted record — restore instead of creating duplicate
    existing_deleted = @buyable.entity_buyers.where(contact_id: contact.id, is_deleted: true).first
    if existing_deleted
      existing_deleted.update!(is_deleted: false, role: role, position: existing_count, notes: params[:notes])
      return render json: buyer_json(existing_deleted), status: :created
    end

    buyer = @buyable.entity_buyers.build(
      company: @company,
      contact: contact,
      role: role,
      position: params[:position] || existing_count,
      notes: params[:notes]
    )

    if buyer.save
      render json: buyer_json(buyer), status: :created
    else
      render json: { errors: buyer.errors.full_messages }, status: :unprocessable_entity
    end
  end

  # PATCH /api/v1/:entity/:entity_id/buyers/:id
  def update
    return unless authorize_action!(resource_key, 'update')

    if @entity_buyer.update(buyer_params)
      render json: buyer_json(@entity_buyer)
    else
      render json: { errors: @entity_buyer.errors.full_messages }, status: :unprocessable_entity
    end
  end

  # DELETE /api/v1/:entity/:entity_id/buyers/:id
  def destroy
    return unless authorize_action!(resource_key, 'update')

    @entity_buyer.update(is_deleted: true)
    head :no_content
  end

  private

  def set_buyable
    if params[:deal_id]
      @buyable = @company.deals.find(params[:deal_id])
      @resource_key = 'deals'
    elsif params[:quote_id]
      @buyable = @company.quotes.find(params[:quote_id])
      @resource_key = 'quotes'
    elsif params[:invoice_id]
      @buyable = @company.invoices.find(params[:invoice_id])
      @resource_key = 'invoices'
    else
      render json: { error: 'Parent resource not found' }, status: :not_found
    end
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Parent resource not found' }, status: :not_found
  end

  def set_entity_buyer
    @entity_buyer = @buyable.entity_buyers.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Buyer not found' }, status: :not_found
  end

  def resource_key
    @resource_key || 'deals'
  end

  def buyer_params
    params.permit(:role, :position, :notes)
  end

  def buyer_json(eb)
    {
      id: eb.id,
      contact_id: eb.contact_id,
      contact: {
        id: eb.contact.id,
        first_name: eb.contact.first_name,
        last_name: eb.contact.last_name,
        full_name: "#{eb.contact.first_name} #{eb.contact.last_name}".strip,
        email: eb.contact.email,
        phone: eb.contact.phone,
        street: eb.contact.street,
        city: eb.contact.city,
        state: eb.contact.state,
        zip: eb.contact.zip
      },
      role: eb.role,
      role_label: eb.role_label,
      position: eb.position,
      notes: eb.notes,
      created_at: eb.created_at
    }
  end
end
