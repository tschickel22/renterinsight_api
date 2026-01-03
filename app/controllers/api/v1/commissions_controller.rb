class Api::V1::CommissionsController < ApplicationController
  before_action :set_company_scope
  before_action :set_commission, only: [:show, :update, :destroy, :approve, :reject, :mark_paid, :audit_trail]

  def index
    return unless authorize_action!('commissions', 'read')

    commissions = @company.commissions.includes(:user, :deal, :commission_rule, :location)

    # RBAC + Location filtering
    if current_user.uses_rbac? && !current_user.effective_admin?
      location_ids = permission_service.accessible_location_ids
      commissions = location_ids.any? ? 
        commissions.where(location_id: location_ids) : 
        commissions.none
    end

    commissions = commissions.for_current_location

    # Apply filters
    commissions = apply_filters(commissions)

    # Sorting
    sort_by = params[:sort_by] || 'created_at'
    sort_order = params[:sort_order] || 'desc'
    commissions = commissions.order("#{sort_by} #{sort_order}")

    # Pagination
    page = params[:page]&.to_i || 1
    per_page = params[:per_page]&.to_i || 50
    total = commissions.count
    commissions = commissions.offset((page - 1) * per_page).limit(per_page)

    render json: {
      commissions: commissions.map { |c| serialize_commission(c) },
      meta: {
        total: total,
        page: page,
        per_page: per_page,
        total_pages: (total.to_f / per_page).ceil
      }
    }
  end

  def show
    return unless authorize_action!('commissions', 'read')
    render json: { commission: serialize_commission(@commission, include_audit: true) }
  end

  def create
    return unless authorize_action!('commissions', 'create')

    commission = @company.commissions.build(commission_params)
    commission.status = 'pending'

    # Auto-assign location from deal
    if commission.deal && commission.deal.location_id
      commission.location_id = commission.deal.location_id
    end

    # RBAC: Location-tier users can only create in their locations
    if current_user.uses_rbac? && !current_user.effective_admin?
      location_ids = permission_service.accessible_location_ids
      if location_ids.any? && !location_ids.include?(commission.location_id)
        render json: { error: 'You do not have permission to create commissions for this location' }, status: :forbidden
        return
      end
    end

    if commission.save
      # Create audit entry
      commission.audit_entries.create!(
        user: current_user,
        action: 'created',
        new_value: commission.as_json(only: [:commission_type, :rate, :amount, :status, :notes])
      )

      render json: { commission: serialize_commission(commission) }, status: :created
    else
      render json: { errors: commission.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def update
    return unless authorize_action!('commissions', 'update')

    # Can only update pending commissions
    unless @commission.can_edit?
      render json: { error: 'Only pending commissions can be edited' }, status: :unprocessable_entity
      return
    end

    # Track previous values for audit
    previous_values = @commission.slice('commission_type', 'rate', 'amount', 'notes')

    if @commission.update(commission_params)
      # Create audit entry
      @commission.audit_entries.create!(
        user: current_user,
        action: 'updated',
        previous_value: previous_values,
        new_value: commission_params.to_h,
        notes: params[:notes]
      )

      render json: { commission: serialize_commission(@commission) }
    else
      render json: { errors: @commission.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def destroy
    return unless authorize_action!('commissions', 'delete')

    # Can only delete pending commissions
    unless @commission.can_edit?
      render json: { error: 'Only pending commissions can be deleted' }, status: :unprocessable_entity
      return
    end

    @commission.destroy
    head :no_content
  end

  def approve
    return unless authorize_action!('commissions', 'approve')

    unless @commission.can_approve?
      render json: { error: 'Commission cannot be approved in its current state' }, status: :unprocessable_entity
      return
    end

    begin
      @commission.approve!(current_user, notes: params[:notes])
      render json: { commission: serialize_commission(@commission) }
    rescue StandardError => e
      render json: { error: e.message }, status: :unprocessable_entity
    end
  end

  def reject
    return unless authorize_action!('commissions', 'approve')

    unless @commission.can_cancel?
      render json: { error: 'Commission cannot be rejected in its current state' }, status: :unprocessable_entity
      return
    end

    begin
      @commission.reject!(current_user, notes: params[:notes])
      render json: { commission: serialize_commission(@commission) }
    rescue StandardError => e
      render json: { error: e.message }, status: :unprocessable_entity
    end
  end

  def mark_paid
    return unless authorize_action!('commissions', 'pay')

    unless @commission.can_mark_paid?
      render json: { error: 'Only approved commissions can be marked as paid' }, status: :unprocessable_entity
      return
    end

    begin
      @commission.mark_paid!(current_user, notes: params[:notes])
      render json: { commission: serialize_commission(@commission) }
    rescue StandardError => e
      render json: { error: e.message }, status: :unprocessable_entity
    end
  end

  def audit_trail
    return unless authorize_action!('commissions', 'read')

    entries = @commission.audit_entries.includes(:user)

    render json: {
      audit_entries: entries.map { |entry| serialize_audit_entry(entry) }
    }
  end

  def stats
    return unless authorize_action!('commissions', 'read')

    commissions = @company.commissions.for_current_location

    # RBAC filtering
    if current_user.uses_rbac? && !current_user.effective_admin?
      location_ids = permission_service.accessible_location_ids
      commissions = location_ids.any? ? 
        commissions.where(location_id: location_ids) : 
        commissions.none
    end

    # Calculate stats
    stats = {
      total_count: commissions.count,
      total_amount: commissions.sum(:amount).to_f,
      pending_count: commissions.pending.count,
      pending_amount: commissions.pending.sum(:amount).to_f,
      approved_count: commissions.approved.count,
      approved_amount: commissions.approved.sum(:amount).to_f,
      paid_count: commissions.paid.count,
      paid_amount: commissions.paid.sum(:amount).to_f,
      cancelled_count: commissions.cancelled.count,
      cancelled_amount: commissions.cancelled.sum(:amount).to_f
    }

    # By type
    stats[:by_type] = {
      flat: commissions.where(commission_type: 'flat').sum(:amount).to_f,
      percentage: commissions.where(commission_type: 'percentage').sum(:amount).to_f,
      tiered: commissions.where(commission_type: 'tiered').sum(:amount).to_f
    }

    # By sales rep (top 5)
    stats[:top_earners] = commissions.paid
      .group(:user_id)
      .sum(:amount)
      .sort_by { |_, amount| -amount }
      .first(5)
      .map do |user_id, total|
        user = User.find(user_id)
        {
          user_id: user_id,
          user_name: user.name,
          total_earned: total.to_f
        }
      end

    render json: stats
  end

  def calculate
    return unless authorize_action!('commissions', 'read')

    deal = @company.deals.find(params[:deal_id])
    rule = @company.commission_rules.find(params[:rule_id])

    calculated_amount = rule.calculate(deal.value)

    render json: {
      deal_id: deal.id,
      deal_value: deal.value,
      rule_id: rule.id,
      rule_name: rule.name,
      rule_type: rule.rule_type,
      commission_amount: calculated_amount
    }
  rescue ActiveRecord::RecordNotFound => e
    render json: { error: e.message }, status: :not_found
  end

  private

  def set_commission
    @commission = @company.commissions.find(params[:id])

    # RBAC: Check location access
    if current_user.uses_rbac? && !current_user.effective_admin?
      location_ids = permission_service.accessible_location_ids
      if location_ids.any? && @commission.location_id && !location_ids.include?(@commission.location_id)
        render json: { error: 'You do not have permission to access this commission' }, status: :forbidden
        return
      end
    end
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Commission not found' }, status: :not_found
  end

  def commission_params
    params.require(:commission).permit(
      :deal_id,
      :user_id,
      :commission_rule_id,
      :commission_type,
      :rate,
      :amount,
      :notes,
      custom_fields: {}
    )
  end

  def apply_filters(commissions)
    # Filter by status
    commissions = commissions.where(status: params[:status]) if params[:status].present?

    # Filter by type
    commissions = commissions.where(commission_type: params[:type]) if params[:type].present?

    # Filter by user (sales rep)
    commissions = commissions.where(user_id: params[:user_id]) if params[:user_id].present?

    # Filter by deal
    commissions = commissions.where(deal_id: params[:deal_id]) if params[:deal_id].present?

    # Filter by location
    commissions = commissions.where(location_id: params[:location_id]) if params[:location_id].present?

    # Filter by date range
    if params[:start_date].present?
      commissions = commissions.where('created_at >= ?', Date.parse(params[:start_date]))
    end

    if params[:end_date].present?
      commissions = commissions.where('created_at <= ?', Date.parse(params[:end_date]).end_of_day)
    end

    # Filter by paid date range
    if params[:paid_start_date].present?
      commissions = commissions.where('paid_date >= ?', Date.parse(params[:paid_start_date]))
    end

    if params[:paid_end_date].present?
      commissions = commissions.where('paid_date <= ?', Date.parse(params[:paid_end_date]))
    end

    commissions
  end

  def serialize_commission(commission, include_audit: false)
    data = {
      id: commission.id,
      dealId: commission.deal_id,
      salesPersonId: commission.user_id,
      salesPersonName: commission.user.name,
      commissionRuleId: commission.commission_rule_id,
      locationId: commission.location_id,
      type: commission.commission_type,
      rate: commission.rate&.to_f,
      amount: commission.amount.to_f,
      status: commission.status,
      paidDate: commission.paid_date,
      notes: commission.notes,
      customFields: commission.custom_fields || {},
      createdAt: commission.created_at,
      updatedAt: commission.updated_at
    }

    # Include related data
    if commission.deal
      data[:deal] = {
        id: commission.deal.id,
        name: commission.deal.name,
        value: commission.deal.value&.to_f,
        stage: commission.deal.stage
      }
    end

    if commission.commission_rule
      data[:commissionRule] = {
        id: commission.commission_rule.id,
        name: commission.commission_rule.name,
        type: commission.commission_rule.rule_type
      }
    end

    if commission.location
      data[:location] = {
        id: commission.location.id,
        name: commission.location.name
      }
    end

    # Include audit trail if requested
    if include_audit
      data[:auditTrail] = commission.audit_entries.includes(:user).map { |entry| serialize_audit_entry(entry) }
    end

    data
  end

  def serialize_audit_entry(entry)
    {
      id: entry.id,
      commissionId: entry.commission_id,
      userId: entry.user_id,
      userName: entry.user.name,
      action: entry.action,
      actionDisplay: entry.action_display,
      previousValue: entry.previous_value,
      newValue: entry.new_value,
      notes: entry.notes,
      changesSummary: entry.changes_summary,
      timestamp: entry.created_at
    }
  end
end
