# frozen_string_literal: true

class Api::V1::PurchaseOrdersController < ApplicationController
  before_action :set_company_scope
  before_action :set_purchase_order, only: [:show, :update, :destroy, :send_to_supplier, :cancel, :receiving_history]

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
      purchase_orders = purchase_orders.joins(:supplier).where(
        'purchase_orders.po_number ILIKE ? OR suppliers.name ILIKE ?',
        search_term, search_term
      )
    end

    # Status filter (supports comma-separated values)
    if params[:status].present?
      statuses = params[:status].split(',').map(&:strip)
      purchase_orders = purchase_orders.where(status: statuses)
    end

    # Supplier filter
    purchase_orders = purchase_orders.where(supplier_id: params[:supplier_id]) if params[:supplier_id].present?

    # Pagination
    page = (params[:page] || 1).to_i
    per_page = [(params[:per_page] || 50).to_i, 200].min
    total_count = purchase_orders.count
    
    purchase_orders = purchase_orders
      .includes(:supplier, :location, :created_by, lines: :part)
      .order(order_date: :desc, created_at: :desc)
      .offset((page - 1) * per_page)
      .limit(per_page)

    render json: {
      items: purchase_orders.as_json(
        methods: [:supplier_name, :location_name, :created_by_name],
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

    render json: @purchase_order.as_json(
      methods: [:supplier_name, :location_name, :created_by_name],
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
  end

  def create
    return unless authorize_action!('inventory', 'create')

    purchase_order = @company.purchase_orders.build(purchase_order_params)
    
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

    if @purchase_order.update(purchase_order_params)
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

  private

  def set_purchase_order
    @purchase_order = @company.purchase_orders.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Purchase order not found' }, status: :not_found
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
