# frozen_string_literal: true

# My Homes in the buyer portal: the homes this buyer designed and saved on
# the dealer's website. Retail only, as the buyer was shown.
module Api
  module Portal
    class TruebuildDesignsController < BaseController
      # GET /api/portal/truebuild_designs
      def index
        designs = @company.truebuild_designs.includes(variant: :catalog_plan).order(created_at: :desc)
        designs = designs.where(lead_id: buyer_lead_ids).or(designs.where(contact_id: buyer_contact_ids))
                         .or(designs.where('LOWER(truebuild_designs.buyer_email) = ?', current_buyer_access.email.to_s.downcase))
        render json: { designs: designs.limit(50).map { |d| design_json(d) } }
      end

      private

      def lead_portal_allowed? = true

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
          image: d.vehicle&.try(:primary_image_url) || Array(d.vehicle&.try(:image_urls)).first || d.variant.try(:image_url),
          link: Truebuild::DesignSaver.design_url(d)
        }
      end
    end
  end
end
