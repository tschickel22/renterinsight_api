# frozen_string_literal: true

# Copies TrueView work between environments (Truebuild::DrawingTransfer),
# driven by script/truebuild_transfer.rb. Platform admins only; platform
# data, so no company scope.
class Api::Admin::TrueviewTransferController < ApplicationController
  before_action :require_platform_admin!

  # GET /api/admin/trueview_transfer?kind=renders&after_id=0&limit=100
  def export
    render json: Truebuild::DrawingTransfer.export(params[:kind].to_s, after_id: params[:after_id].to_i,
                                                                       limit: (params[:limit].presence || Truebuild::DrawingTransfer::PAGE).to_i)
  rescue ArgumentError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  # POST /api/admin/trueview_transfer { kind, rows: [...] }
  def import
    rows = params.require(:rows).map { |r| r.permit!.to_h }
    render json: Truebuild::DrawingTransfer.import!(params[:kind].to_s, rows)
  rescue ArgumentError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end
end
