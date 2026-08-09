# frozen_string_literal: true

class Api::V1::LabelsController < ApplicationController
  before_action :set_company_scope

  # GET /api/v1/company/labels
  #
  # Deliberately open to any authenticated user of the company. Labels are the
  # terminology every screen renders with ("Prospecting", "Sales Deals"), not a
  # settings screen, and gating them on company_settings meant that narrowing a
  # role broke the vocabulary of the whole app for that persona. Reading them
  # exposes nothing but the dealer's own choice of words; changing them still
  # requires company_settings:update below.
  def show
    render json: {
      industry: @company.industry,
      labels: @company.resolved_labels,
      defaults: @company.label_defaults,
      overrides: @company.label_overrides
    }
  end

  # PUT /api/v1/company/labels
  def update
    return unless authorize_action!('company_settings', 'update')

    submitted = params[:labels].respond_to?(:to_unsafe_h) ? params[:labels].to_unsafe_h : (params[:labels] || {})
    @company.save_label_overrides(submitted)

    render json: {
      industry: @company.industry,
      labels: @company.resolved_labels,
      defaults: @company.label_defaults,
      overrides: @company.label_overrides
    }
  end

  # DELETE /api/v1/company/labels/:key
  def destroy
    return unless authorize_action!('company_settings', 'update')

    @company.clear_label_override!(params[:key])

    render json: {
      industry: @company.industry,
      labels: @company.resolved_labels,
      defaults: @company.label_defaults,
      overrides: @company.label_overrides
    }
  end

  # POST /api/v1/company/labels/reset
  def reset
    return unless authorize_action!('company_settings', 'update')

    @company.reset_label_overrides!

    render json: {
      industry: @company.industry,
      labels: @company.resolved_labels,
      defaults: @company.label_defaults,
      overrides: {}
    }
  end
end
