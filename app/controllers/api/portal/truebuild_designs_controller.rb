# frozen_string_literal: true

# My Homes in the buyer portal: the homes this buyer designed and saved on
# the dealer's website. Retail only, as the buyer was shown.
module Api
  module Portal
    class TruebuildDesignsController < BaseController
      # GET /api/portal/truebuild_designs
      def index
        render json: { designs: mine.includes(variant: :catalog_plan).order(created_at: :desc).limit(50).map { |d| design_json(d) } }
      end

      # POST /api/portal/truebuild_designs/:id/shared
      # Shared from My Homes: counted and raised for the dealer to follow up,
      # as a share from the website is.
      def shared
        design = mine.find_by(id: params[:id])
        return render json: { error: 'Not found' }, status: :not_found unless design

        design.track!('shared')
        head :no_content
      end

      private

      def lead_portal_allowed? = true

      # By the buyer record only. Matching on email too let anyone who
      # changed their login email see designs saved under it.
      def mine
        designs = @company.truebuild_designs
        designs.where(lead_id: buyer_lead_ids).or(designs.where(contact_id: buyer_contact_ids))
      end

      def buyer_lead_ids
        current_buyer_access.buyer_type == 'Lead' ? [current_buyer_access.buyer_id] : []
      end

      def buyer_contact_ids
        current_buyer_access.buyer_type == 'Contact' ? [current_buyer_access.buyer_id] : []
      end

      def design_json(d)
        snap = d.price_snapshot
        plan = d.variant.catalog_plan
        {
          id: d.id, name: d.name, plan: plan.name, series: plan.series, model_number: d.variant.model_number,
          beds: d.variant.beds, baths: d.variant.baths&.to_f, width_ft: d.variant.width_ft, length_ft: d.variant.length_ft,
          options: CatalogOption.where(id: d.option_ids).pluck(:name),
          price: snap['show_prices'] ? snap['total'] : nil, saved_at: d.created_at,
          image: Array(d.vehicle&.public_image_urls).first || d.variant.media.dig('photos', 0, 'url') || d.variant.media.dig('elevations', 0),
          link: Truebuild::DesignSaver.design_url(d)
        }
      end
    end
  end
end
