# frozen_string_literal: true

class Api::V1::PurchaseOrdersController < ApplicationController
  before_action :set_company_scope
  before_action :set_purchase_order, only: [:show, :update, :destroy, :send_to_supplier, :cancel, :receiving_history, :post_to_accounting,
                                            :receive_home, :email]

  def index
    return unless authorize_action!('inventory', 'read')

    # Base query with tenant isolation
    purchase_orders = @company.purchase_orders.where(is_deleted: [false, nil])

    # RBAC + Location Filtering
    if current_user.uses_rbac?
      unless current_user.effective_admin?
        location_ids = permission_service.accessible_location_ids
        purchase_orders = location_ids.any? ? 
          purchase_orders.where(location_id: location_ids) : 
          purchase_orders.none
      end
    end

    # Location filter (from UI)
    if params[:location_id].present?
      purchase_orders = purchase_orders.where(location_id: params[:location_id])
    end

    # Date range filter
    if params[:start_date].present?
      purchase_orders = purchase_orders.where('order_date >= ?', params[:start_date])
    end
    if params[:end_date].present?
      purchase_orders = purchase_orders.where('order_date <= ?', params[:end_date])
    end

    # Search
    if params[:search].present?
      search_term = "%#{params[:search]}%"
      purchase_orders = purchase_orders.joins(:supplier).left_joins(deal: :contact).where(
        'purchase_orders.po_number ILIKE :q OR vendors.name ILIKE :q OR deals.name ILIKE :q OR contacts.first_name ILIKE :q OR contacts.last_name ILIKE :q',
        q: search_term
      )
    end

    # Status filter (supports comma-separated values)
    if params[:status].present?
      statuses = params[:status].split(',').map(&:strip)
      purchase_orders = purchase_orders.where(status: statuses)
    end

    # Supplier filter
    purchase_orders = purchase_orders.where(supplier_id: params[:supplier_id]) if params[:supplier_id].present?
    # A deal's factory POs
    purchase_orders = purchase_orders.where(deal_id: params[:deal_id]) if params[:deal_id].present?

    # Pagination
    page = (params[:page] || 1).to_i
    per_page = [(params[:per_page] || 50).to_i, 200].min
    total_count = purchase_orders.count
    
    purchase_orders = purchase_orders
      .includes(:supplier, :location, :created_by, { deal: %i[contact account] }, lines: :part)
      .order(order_date: :desc, created_at: :desc)
      .offset((page - 1) * per_page)
      .limit(per_page)

    render json: {
      items: purchase_orders.as_json(
        methods: [:supplier_name, :location_name, :created_by_name, :deal_customer_name, :deal_number],
        include: {
          supplier: { only: [:id, :name, :code] },
          location: { only: [:id, :name] },
          created_by: { only: [:id, :first_name, :last_name, :email] },
          lines: {
            methods: [:part_name, :part_number],
            include: {
              part: { only: [:id, :part_number, :name] }
            }
          }
        }
      ),
      meta: {
        total: total_count,
        page: page,
        per_page: per_page,
        total_pages: (total_count.to_f / per_page).ceil
      }
    }
  end

  def show
    return unless authorize_action!('inventory', 'read')

    json = @purchase_order.as_json(
      methods: [:supplier_name, :location_name, :created_by_name, :deal_customer_name],
      include: {
        supplier: { only: [:id, :name, :code, :account_number, :email, :phone] },
        location: { 
          only: [:id, :name, :address_line1, :city, :state, :zip, :phone, :email],
          methods: [:logo]
        },
        company: { 
          only: [:id, :name, :address, :city, :state, :zip, :phone, :email],
          methods: [:logo]
        },
        created_by: { only: [:id, :first_name, :last_name, :email] },
        approved_by: { only: [:id, :first_name, :last_name, :email] },
        lines: {
          methods: [:part_name, :part_number, :percent_received, :status],
          include: {
            part: { only: [:id, :part_number, :name, :description] }
          }
        }
      }
    )
    # A factory PO: the deal it is for, and whether the Deal Sheet changed since.
    if @purchase_order.deal
      d = @purchase_order.deal
      json['deal'] = { 'id' => d.id, 'deal_number' => d.deal_number, 'name' => d.name }
    end
    m = @purchase_order.contact_manufacturer
    json['manufacturer'] = m && { 'id' => m.id, 'name' => m.name }
    json['order_contact'] = @purchase_order.order_contact.stringify_keys
    if @purchase_order.factory_home?
      json['sheet_changed_since'] = Truebuild::FactoryOrder.changed?(@purchase_order)
      v = @purchase_order.received_vehicle
      json['received_vehicle'] = v && { 'id' => v.id, 'serial_number' => v.serial_number, 'stock_number' => v.stock_number }
    end
    render json: json
  end

  def create
    return unless authorize_action!('inventory', 'create')

    purchase_order = @company.purchase_orders.build(purchase_order_params)
    return unless link_deal_and_manufacturer(purchase_order)

    # Auto-assign location_id
    purchase_order.location_id ||= Current.location_id if Current.location_id.present?
    
    # RBAC fallback for location-tier users
    if purchase_order.location_id.nil? && current_user.uses_rbac? && !current_user.effective_admin?
      location_ids = permission_service.accessible_location_ids
      purchase_order.location_id = location_ids.first if location_ids.any?
    end

    # Set created_by
    purchase_order.created_by_id = current_user.id

    if purchase_order.save
      render json: purchase_order.as_json(
        include: {
          supplier: { only: [:id, :name] },
          location: { only: [:id, :name] },
          lines: { methods: [:part_name, :part_number], include: { part: { only: [:id, :part_number, :name] } } }
        }
      ), status: :created
    else
      render json: { errors: purchase_order.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def update
    return unless authorize_action!('inventory', 'update')

    @purchase_order.assign_attributes(purchase_order_params)
    return unless link_deal_and_manufacturer(@purchase_order)

    if @purchase_order.save
      render json: @purchase_order.as_json(
        include: {
          supplier: { only: [:id, :name] },
          location: { only: [:id, :name] },
          lines: { methods: [:part_name, :part_number], include: { part: { only: [:id, :part_number, :name] } } }
        }
      )
    else
      render json: { errors: @purchase_order.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def destroy
    return unless authorize_action!('inventory', 'delete')

    @purchase_order.update(is_deleted: true, deleted_at: Time.current)
    head :no_content
  end

  def stats
    return unless authorize_action!('inventory', 'read')

    base_scope = @company.purchase_orders.where(is_deleted: [false, nil])
    
    # Apply same filters as index for responsive stats
    if params[:location_id].present?
      base_scope = base_scope.where(location_id: params[:location_id])
    end
    
    if params[:start_date].present?
      base_scope = base_scope.where('order_date >= ?', params[:start_date])
    end
    
    if params[:end_date].present?
      base_scope = base_scope.where('order_date <= ?', params[:end_date])
    end
    
    if params[:status].present?
      base_scope = base_scope.where(status: params[:status])
    end
    
    if params[:supplier_id].present?
      base_scope = base_scope.where(supplier_id: params[:supplier_id])
    end

    render json: {
      total_orders: base_scope.count,
      draft_count: base_scope.where(status: 'draft').count,
      sent_count: base_scope.where(status: 'sent').count,
      received_count: base_scope.where(status: 'received').count,
      cancelled_count: base_scope.where(status: 'cancelled').count,
      total_value: base_scope.sum(:total_amount).to_f.round(2),
      average_order_value: base_scope.average(:total_amount)&.to_f&.round(2) || 0.0
    }
  end

  def send_to_supplier
    return unless authorize_action!('inventory', 'update')

    if @purchase_order.draft?
      @purchase_order.update(status: 'sent', sent_at: Time.current)
      render json: { success: true, message: 'Purchase order sent to supplier' }
    else
      render json: { error: 'Can only send draft purchase orders' }, status: :unprocessable_entity
    end
  end

  def cancel
    return unless authorize_action!('inventory', 'update')

    if @purchase_order.received?
      render json: { error: 'Cannot cancel a received purchase order' }, status: :unprocessable_entity
    else
      @purchase_order.update(status: 'cancelled', cancelled_at: Time.current)
      render json: { success: true, message: 'Purchase order cancelled' }
    end
  end

  def receiving_history
    return unless authorize_action!('inventory', 'read')

    transactions = InventoryTransaction.joins(:purchase_order_line)
      .where(purchase_order_lines: { purchase_order_id: @purchase_order.id })
      .where(transaction_type: 'receive')
      .includes(:part, :location, :created_by)
      .order(transaction_date: :desc)

    render json: transactions.as_json(
      include: {
        part: { only: [:id, :sku, :name] },
        location: { only: [:id, :name] },
        created_by: { only: [:id, :first_name, :last_name] }
      }
    )
  end

  # POST /api/v1/purchase_orders/:id/receive-home  { serial_number, vehicle_id?, stock_number? }
  # A factory PO's home arrived: records it in inventory (or links one already
  # there) and to the deal. Posts nothing; the cost comes with the factory invoice.
  def receive_home
    return unless authorize_action!('inventory', 'update')

    vehicle = params[:vehicle_id].present? ? @company.vehicles.find_by(id: params[:vehicle_id]) : nil
    return render json: { error: 'Home not found' }, status: :not_found if params[:vehicle_id].present? && !vehicle

    Truebuild::FactoryOrder.receive!(@purchase_order, serial_number: params[:serial_number], vehicle: vehicle,
                                                      stock_number: params[:stock_number], user: current_user)
    @purchase_order.reload
    render json: { status: @purchase_order.status, received_vehicle_id: @purchase_order.received_vehicle_id }
  rescue Truebuild::FactoryOrder::Refused, ActiveRecord::RecordInvalid => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  # POST /api/v1/purchase-orders/:id/email  { to?, cc?, message? }
  # Emails the PO as a PDF to the manufacturer's orders contact (or the rep
  # when it has none), else the supplier; a draft is marked sent.
  def email
    return unless authorize_action!('inventory', 'update')

    to = params[:to].presence || @purchase_order.order_contact[:email]
    return render json: { error: 'No email to send it to: add one for the manufacturer or supplier, or type one' }, status: :unprocessable_entity if to.blank?
    unless to.to_s.split(/[,;]\s*/).all? { |e| e.match?(URI::MailTo::EMAIL_REGEXP) }
      return render json: { error: "#{to} is not an email address" }, status: :unprocessable_entity
    end
    if @purchase_order.status == 'cancelled'
      return render json: { error: 'This purchase order was cancelled' }, status: :unprocessable_entity
    end

    deliver_po = ->(from) do
      PurchaseOrderMailer.order(@purchase_order, to: to.to_s.split(/[,;]\s*/), cc: params[:cc].presence, message: params[:message],
                                                 sender: current_user, from: from).deliver_now
    end
    begin
      begin
        deliver_po.call(nil)
      rescue StandardError => e
        # The company's or location's sender is not verified with the provider:
        # send from the platform's, under the dealer's name.
        fallback = PurchaseOrderMailer.platform_from(@company)
        raise unless e.message.to_s.match?(/not verified/i) && fallback

        Rails.logger.warn("[PO email] #{@purchase_order.po_number}: sender not verified, using the platform sender")
        deliver_po.call(fallback)
      end
    rescue StandardError => e
      Rails.logger.error("[PO email] #{@purchase_order.po_number}: #{e.class} #{e.message}")
      return render json: { error: "The email could not be sent: #{e.message}" }, status: :bad_gateway
    end
    saved = save_order_contact(to.to_s.split(/[,;]\s*/).first) if ActiveModel::Type::Boolean.new.cast(params[:save_contact])
    attrs = { emailed_at: Time.current, emailed_to: to }
    attrs.merge!(status: 'sent', sent_at: Time.current) if @purchase_order.draft?
    @purchase_order.update_columns(attrs.merge(updated_at: Time.current))
    render json: { status: @purchase_order.status, emailed_at: @purchase_order.emailed_at, emailed_to: to, saved_contact: saved }
  end

  # POST /api/v1/purchase_orders/:id/post_to_accounting
  def post_to_accounting
    return unless authorize_action!('purchase_orders', 'update')

    result = Accounting::PurchaseOrderPostingService.new(@purchase_order).post!
    if result
      render json: { message: 'Posted to accounting', journal_entry_id: result.id }
    else
      render json: { message: 'Already posted or auto-post disabled' }, status: :unprocessable_entity
    end
  rescue => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  private

  def set_purchase_order
    @purchase_order = @company.purchase_orders.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Purchase order not found' }, status: :not_found
  end

  # The address typed when emailing, kept for next time: the manufacturer's
  # PO email (adding it to Manufacturer/Warranty if it is not there yet),
  # else the supplier's email when it has none.
  def save_order_contact(email)
    return nil if email.blank?

    if (m = @purchase_order.contact_manufacturer)
      cm = @company.company_manufacturers.find_or_initialize_by(manufacturer_id: m.id)
      cm.active = true if cm.new_record?
      # The rep's address typed in again is not a separate orders contact.
      cm.po_email = email unless email.casecmp?(cm.effective_contact_email.to_s)
      cm.save! if cm.changed?
      'manufacturer'
    elsif @purchase_order.supplier && @purchase_order.supplier.email.blank?
      @purchase_order.supplier.update!(email: email)
      'supplier'
    end
  rescue ActiveRecord::RecordInvalid => e
    Rails.logger.warn("[PO email] could not save #{email} as the order contact: #{e.message}")
    nil
  end

  # A PO for a deal, or placed with a manufacturer: both must be this
  # company's. A manufacturer stands in for the supplier (its supplier record
  # is made for it, so the factory invoice can be entered as a bill).
  def link_deal_and_manufacturer(po)
    raw = params[:purchase_order] || {}
    if raw.key?(:deal_id)
      deal = raw[:deal_id].present? ? @company.deals.find_by(id: raw[:deal_id]) : nil
      return render(json: { error: 'Deal not found' }, status: :not_found) && false if raw[:deal_id].present? && !deal

      po.deal = deal
    end
    if raw[:manufacturer_id].present?
      manufacturer = Manufacturer.visible_to_company(@company.id).find_by(id: raw[:manufacturer_id])
      return render(json: { error: 'Manufacturer not found' }, status: :not_found) && false unless manufacturer

      po.manufacturer = manufacturer
      po.supplier = Truebuild::FactoryOrder.supplier_for(@company, manufacturer)
      po.vendor_id = po.supplier_id
    elsif raw.key?(:manufacturer_id)
      po.manufacturer = nil
    end
    true
  end

  def purchase_order_params
    params.require(:purchase_order).permit(
      :supplier_id,
      :location_id,
      :order_date,
      :expected_delivery_date,
      :status,
      :subtotal,
      :tax_amount,
      :shipping_cost,
      :total_amount,
      :notes,
      :terms,
      :shipping_method,
      :tracking_number,
      :ship_to_name,
      :ship_to_address1,
      :ship_to_address2,
      :ship_to_city,
      :ship_to_state,
      :ship_to_zip,
      :ship_to_country,
      lines_attributes: [
        :id,
        :part_id,
        :line_number,
        :quantity_ordered,
        :unit_cost,
        :discount_percent,
        :description,
        :notes,
        :expected_date,
        :manufacturer_part_no,
        :_destroy
      ]
    )
  end
end
