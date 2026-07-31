# frozen_string_literal: true

# Scan a client's existing site into a reusable Content Profile.
#
# Scanning must live here (CORS, the Anthropic key, a minutes-long crawl), but
# PROJECTION DOES NOT. The nine templates are TypeScript data in the frontend,
# so the frontend projects the profile into them — that avoids duplicating the
# templates across two repos and makes switching designs instant instead of a
# round trip per template. This controller serves profiles; the client renders.
#
# Platform admin only, EXCEPT #by_token — the whole point of the shared preview
# is that a salesperson can send it to someone with no account.
class Api::V1::SiteContentProfilesController < ApplicationController
  skip_before_action :authenticate, only: [:by_token]

  before_action :require_platform_admin!, except: [:by_token]
  before_action :set_company_scope, except: [:by_token]
  before_action :set_profile, only: %i[show destroy rotate_preview_token update]

  def index
    profiles = SiteContentProfile.where(company_id: @company.id).order(created_at: :desc).limit(100)
    render json: { items: profiles.map { |p| summary(p) } }
  end

  def show
    render json: detail(@profile)
  end

  # POST /api/v1/site_content_profiles  { source_url:, display_name? }
  def create
    url = params[:source_url].to_s.strip

    # Fail fast on an unsafe URL so the admin sees a real error now, rather than
    # a job that dies quietly three minutes later.
    begin
      SiteProfiles::UrlGuard.validate!(url)
    rescue SiteProfiles::UrlGuard::BlockedUrlError => e
      return render json: { error: e.message }, status: :unprocessable_entity
    end

    profile = SiteContentProfile.create!(
      company_id: @company.id,
      location_id: params[:location_id].presence,
      created_by: current_user,
      source_url: url,
      display_name: params[:display_name].presence,
      preview_template_ids: Array(params[:preview_template_ids]).map(&:to_s),
      status: 'pending'
    )

    SiteProfileScanJob.perform_later(profile.id)
    render json: detail(profile), status: :created
  end

  # Curate which designs a customer sees, or set an expiry, without reissuing
  # the link.
  def update
    @profile.update!(
      display_name: params.fetch(:display_name, @profile.display_name),
      preview_template_ids: params.key?(:preview_template_ids) ? Array(params[:preview_template_ids]).map(&:to_s) : @profile.preview_template_ids,
      preview_expires_at: params.fetch(:preview_expires_at, @profile.preview_expires_at)
    )
    render json: detail(@profile)
  end

  def rotate_preview_token
    @profile.rotate_preview_token!
    render json: { preview_token: @profile.preview_token }
  end

  def destroy
    @profile.destroy!
    head :no_content
  end

  # GET /api/v1/site_content_profiles/by_token/:token
  #
  # PUBLIC. Deliberately narrow: returns the content needed to render a preview
  # and nothing else — not the source URL, not the company, not who scanned it.
  def by_token
    profile = SiteContentProfile.find_by(preview_token: params[:token])
    return render json: { error: 'Preview not found' }, status: :not_found if profile.nil? || !profile.shareable?

    render json: {
      display_name: profile.display_name,
      profile: public_profile(profile),
      template_ids: profile.visible_template_ids,
      inventory_embed_config: inventory_config_for(profile.company)
    }
  end

  private

  def set_profile
    @profile = SiteContentProfile.find_by(id: params[:id], company_id: @company.id)
    render json: { error: 'Not found' }, status: :not_found if @profile.nil?
  end

  # Everything the client needs to project, minus the provenance.
  def public_profile(profile)
    profile.profile.slice('schema_version', 'brand', 'contact', 'copy', 'media', 'links', 'integrations', 'seo')
  end

  def inventory_config_for(company)
    token = company.try(:public_inventory_token)
    return nil if token.blank? || !company.try(:public_inventory_enabled)

    { 'token' => token, 'company_id' => company.id, 'enabled' => true }
  end

  def summary(profile)
    {
      id: profile.id,
      source_url: profile.source_url,
      display_name: profile.display_name,
      status: profile.status,
      preview_token: profile.preview_token,
      preview_expires_at: profile.preview_expires_at,
      preview_template_ids: profile.preview_template_ids,
      created_at: profile.created_at,
      page_count: profile.report['page_count']
    }
  end

  def detail(profile)
    summary(profile).merge(
      profile: profile.profile,
      report: profile.report,
      schema_version: profile.schema_version,
      robots_allowed: profile.robots_allowed,
      error_message: profile.error_message,
      inventory_embed_config: inventory_config_for(profile.company)
    )
  end
end
