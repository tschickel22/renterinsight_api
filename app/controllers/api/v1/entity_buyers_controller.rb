# frozen_string_literal: true

# The people on a Deal, Quote or Invoice and their roles (Buyer, Co-Buyer,
# Co-Signer, Guarantor). On a Deal this is the people card; the deal's Buyer and
# Co-Buyer columns follow it (see EntityBuyer, Deal#sync_pointers_from_people!).
#
# Routes:
#   GET    /api/v1/deals/:deal_id/buyers
#   GET    /api/v1/deals/:deal_id/buyers/suggestions
#   POST   /api/v1/deals/:deal_id/buyers      contact_id, or contact: { first_name, last_name, email, phone }
#   PATCH  /api/v1/deals/:deal_id/buyers/:id
#   DELETE /api/v1/deals/:deal_id/buyers/:id
#   (index/create/update/destroy also for quotes and invoices)
#
class Api::V1::EntityBuyersController < ApplicationController
  before_action :set_company_scope
  before_action :set_buyable
  before_action :set_entity_buyer, only: [:update, :destroy]

  # GET /api/v1/:entity/:entity_id/buyers
  def index
    return unless authorize_action!(resource_key, 'read')

    # A deal whose Buyer / Co-Buyer columns are set but whose card is empty
    # (older deals, or ones made before the card was kept in step) shows those
    # people rather than an empty card.
    @buyable.ensure_people_from_pointers! if deal?

    buyers = @buyable.entity_buyers.active.ordered.includes(:contact)
    render json: buyers.map { |eb| buyer_json(eb) }
  end

  # GET /api/v1/deals/:deal_id/buyers/suggestions
  # Contacts on the deal's account who are not on the deal yet. Offered, never
  # added on their own: an account can hold a realtor or a relative.
  def suggestions
    return unless authorize_action!(resource_key, 'read')

    account = people_account
    return render(json: []) unless account

    on_deal = @buyable.entity_buyers.active.pluck(:contact_id) + [@buyable.try(:contact_id), @buyable.try(:co_applicant_contact_id)].compact
    contacts = @company.contacts.where(account_id: account.id).where(is_deleted: [false, nil])
                       .where.not(id: on_deal).order(is_primary: :desc, created_at: :asc).limit(50)
    render json: contacts.map { |c| contact_json(c) }
  end

  # POST /api/v1/:entity/:entity_id/buyers
  def create
    return unless authorize_action!(resource_key, 'update')

    role = params[:role].presence || default_role
    unless EntityBuyer::ROLES.include?(role)
      return render json: { errors: ["#{role} is not a role"] }, status: :unprocessable_entity
    end

    buyer = nil
    error = nil
    ActiveRecord::Base.transaction do
      contact, error = find_or_build_contact
      raise ActiveRecord::Rollback if error

      error = place_on_account(contact)
      raise ActiveRecord::Rollback if error

      buyer = add_to_record(contact, role)
      unless buyer.persisted?
        error = buyer.errors.full_messages.to_sentence
        raise ActiveRecord::Rollback
      end
    end

    return render(json: { errors: [error] }, status: :unprocessable_entity) if error

    render json: buyer_json(buyer.reload), status: :created
  end

  # PATCH /api/v1/:entity/:entity_id/buyers/:id
  def update
    return unless authorize_action!(resource_key, 'update')

    if buyer_params.key?(:role) && leaving_deal_without_buyer?(buyer_params[:role])
      return render json: { errors: [no_buyer_message] }, status: :unprocessable_entity
    end

    if @entity_buyer.update(buyer_params)
      render json: buyer_json(@entity_buyer)
    else
      render json: { errors: @entity_buyer.errors.full_messages }, status: :unprocessable_entity
    end
  end

  # DELETE /api/v1/:entity/:entity_id/buyers/:id
  def destroy
    return unless authorize_action!(resource_key, 'update')

    if leaving_deal_without_buyer?(nil)
      return render json: { errors: [no_buyer_message] }, status: :unprocessable_entity
    end

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

  def deal?
    @buyable.is_a?(Deal)
  end

  def buyer_params
    params.permit(:role, :position, :notes)
  end

  def labels
    @labels ||= @company.resolved_labels
  end

  # First open buying role, else Co-Signer.
  def default_role
    taken = @buyable.entity_buyers.active.pluck(:role)
    (EntityBuyer::PURCHASER_ROLES - taken).first || EntityBuyer::ROLE_COSIGNER
  end

  # The account the record's people belong to: its own, else its Buyer's.
  def people_account
    account = @buyable.try(:account)
    account ||= @buyable.try(:contact)&.account
    account && account.company_id == @company.id ? account : nil
  end

  # Returns [contact, error].
  def find_or_build_contact
    if params[:contact_id].present?
      contact = @company.contacts.find_by(id: params[:contact_id])
      return [nil, 'That contact was not found.'] unless contact

      return [contact, nil]
    end

    attrs = params.fetch(:contact, {}).permit(:first_name, :last_name, :email, :phone)
    return [nil, 'Choose a contact or enter a first name.'] if attrs[:first_name].blank?

    contact = @company.contacts.build(attrs.to_h.merge(
      location_id: @buyable.try(:location_id),
      owner_id: @buyable.try(:owner_id)
    ))
    [contact, nil]
  end

  # People must be on the record's account. A deal with no account gets one:
  # its Buyer's account, else a new household account named after its Buyer
  # (or this person, when they are the first). Returns an error string or nil.
  def place_on_account(contact)
    return save_error(contact) unless deal?

    account = people_account || create_household_account(contact)
    return 'Could not set up an account for this deal.' unless account

    if @buyable.account_id.blank?
      @buyable.update_columns(account_id: account.id, updated_at: Time.current)
      deal_contact = @buyable.contact
      deal_contact.update!(account_id: account.id) if deal_contact && deal_contact.account_id.blank?
    end

    if contact.account_id.present? && contact.account_id != account.id
      return "#{full_name(contact)} is on a different account (#{contact.account&.name}). Add them to #{account.name} first."
    end

    contact.account_id = account.id
    save_error(contact)
  end

  def create_household_account(contact)
    anchor = @buyable.contact || contact
    @company.accounts.create!(
      name: full_name(anchor).presence || 'New customer',
      status: 'active',
      account_type: 'customer',
      email: anchor.email,
      phone: anchor.phone,
      location_id: @buyable.location_id,
      owner_id: @buyable.owner_id
    )
  end

  def save_error(contact)
    return nil if !contact.new_record? && !contact.changed?
    return nil if contact.save

    contact.errors.full_messages.to_sentence
  end

  def add_to_record(contact, role)
    position = @buyable.entity_buyers.active.count
    removed = @buyable.entity_buyers.where(contact_id: contact.id, is_deleted: true).first
    if removed
      removed.update(is_deleted: false, role: role, position: position, notes: params[:notes])
      return removed
    end

    buyer = @buyable.entity_buyers.build(company: @company, contact: contact, role: role,
                                         position: params[:position] || position, notes: params[:notes])
    buyer.save
    buyer
  end

  # A deal with no account must keep a Buyer (it has nobody else to point at).
  def leaving_deal_without_buyer?(new_role)
    deal? && @buyable.account_id.blank? && @entity_buyer.role == EntityBuyer::ROLE_BUYER &&
      new_role.to_s != EntityBuyer::ROLE_BUYER
  end

  def no_buyer_message
    "This #{labels['deal'] || 'deal'} has no account, so it needs a #{labels['buyer'] || 'Buyer'}. Make someone else the #{labels['buyer'] || 'Buyer'} first."
  end

  def full_name(contact)
    [contact.first_name, contact.last_name].compact.join(' ').squish
  end

  def contact_json(c)
    { id: c.id, first_name: c.first_name, last_name: c.last_name, full_name: full_name(c),
      email: c.email, phone: c.phone }
  end

  def buyer_json(eb)
    {
      id: eb.id,
      contact_id: eb.contact_id,
      contact: contact_json(eb.contact).merge(
        street: eb.contact.street, city: eb.contact.city, state: eb.contact.state, zip: eb.contact.zip
      ),
      role: eb.role,
      role_label: labels[EntityBuyer::LABEL_KEYS[eb.role]].presence || eb.role&.titleize,
      position: eb.position,
      notes: eb.notes,
      created_at: eb.created_at
    }
  end
end
