# frozen_string_literal: true

# Change orders on a factory PO already sent (backlog E52, phase 1).
#
#   GET    /api/v1/purchase-orders/:purchase_order_id/change-orders          the list, and what a new one would carry
#   POST   /api/v1/purchase-orders/:purchase_order_id/change-orders          { production_status, notes }
#   PATCH  .../change-orders/:id                                             a draft from the sheet as it is now
#   POST   .../change-orders/:id/email                                       { to?, cc?, message? }  sent to the factory
#   POST   .../change-orders/:id/approve                                     the factory accepted: the PO takes it
#   POST   .../change-orders/:id/void
#   GET    .../change-orders/:id/pdf
class Api::V1::PurchaseOrderChangeOrdersController < ApplicationController
  before_action :set_company_scope
  before_action :set_purchase_order
  before_action :set_change_order, except: %i[index create]

  def index
    return unless authorize_action!('inventory', 'read')

    pending = begin
      d = Truebuild::ChangeOrders.diff(@purchase_order) if @purchase_order.factory_home? && !@purchase_order.draft?
      d && d.values_at('lines', 'colors').any?(&:present?) ? d.slice('lines', 'colors', 'cost_delta') : nil
    rescue Truebuild::ChangeOrders::Refused
      nil
    end
    render json: { change_orders: @purchase_order.change_orders.map { |co| json(co) }, pending: pending,
                   production_statuses: PurchaseOrderChangeOrder::PRODUCTION }
  end

  def create
    return unless authorize_action!('inventory', 'update')

    co = Truebuild::ChangeOrders.create!(@purchase_order, user: current_user, production_status: params[:production_status], notes: params[:notes])
    render json: { change_order: json(co) }, status: :created
  rescue Truebuild::ChangeOrders::Refused, ActiveRecord::RecordInvalid => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def update
    return unless authorize_action!('inventory', 'update')

    Truebuild::ChangeOrders.refresh!(@change_order, production_status: params[:production_status], notes: params[:notes])
    render json: { change_order: json(@change_order.reload) }
  rescue Truebuild::ChangeOrders::Refused, ActiveRecord::RecordInvalid => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def email
    return unless authorize_action!('inventory', 'update')
    return render json: { error: "#{@change_order.label} is #{@change_order.status}" }, status: :unprocessable_entity unless @change_order.open?

    to = params[:to].presence || @purchase_order.order_contact[:email]
    return render json: { error: 'No email to send it to: add one for the manufacturer, or type one' }, status: :unprocessable_entity if to.blank?
    unless to.to_s.split(/[,;]\s*/).all? { |e| e.match?(URI::MailTo::EMAIL_REGEXP) }
      return render json: { error: "#{to} is not an email address" }, status: :unprocessable_entity
    end

    deliver = lambda do |from|
      PurchaseOrderMailer.change_order(@change_order, to: to.to_s.split(/[,;]\s*/), cc: params[:cc].presence, message: params[:message],
                                                      sender: current_user, from: from).deliver_now
    end
    begin
      begin
        deliver.call(nil)
      rescue StandardError => e
        fallback = PurchaseOrderMailer.platform_from(@company)
        raise unless e.message.to_s.match?(/not verified/i) && fallback

        deliver.call(fallback)
      end
    rescue StandardError => e
      Rails.logger.error("[Change order email] #{@change_order.label}: #{e.class} #{e.message}")
      return render json: { error: "The email could not be sent: #{e.message}" }, status: :bad_gateway
    end
    @change_order.update!(status: 'sent', emailed_at: Time.current, emailed_to: to)
    render json: { change_order: json(@change_order) }
  end

  def approve
    return unless authorize_action!('inventory', 'update')

    Truebuild::ChangeOrders.approve!(@change_order)
    render json: { change_order: json(@change_order.reload) }
  rescue Truebuild::ChangeOrders::Refused, ActiveRecord::RecordInvalid => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def void
    return unless authorize_action!('inventory', 'update')

    Truebuild::ChangeOrders.void!(@change_order)
    render json: { change_order: json(@change_order.reload) }
  rescue Truebuild::ChangeOrders::Refused => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def pdf
    return unless authorize_action!('inventory', 'read')

    send_data ChangeOrderPdfGenerator.new(@change_order).generate, filename: "#{@change_order.label}.pdf", type: 'application/pdf',
                                                                     disposition: 'inline'
  end

  private

  def set_purchase_order
    @purchase_order = @company.purchase_orders.find_by(id: params[:purchase_order_id])
    render json: { error: 'Not found' }, status: :not_found unless @purchase_order
  end

  def set_change_order
    @change_order = @purchase_order.change_orders.find_by(id: params[:id])
    render json: { error: 'Not found' }, status: :not_found unless @change_order
  end

  def json(co)
    { id: co.id, label: co.label, number: co.number, status: co.status, production_status: co.production_status,
      production_warning: co.production_warning, lines: co.lines, colors: co.colors, cost_delta: co.cost_delta.to_f,
      notes: co.notes, emailed_at: co.emailed_at&.iso8601, emailed_to: co.emailed_to, approved_at: co.approved_at&.iso8601,
      created_at: co.created_at.iso8601, created_by: co.created_by&.name }
  end
end
