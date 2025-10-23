# frozen_string_literal: true

module Api
  module V1
    class LotMapLayoutsController < ApplicationController
      before_action :set_company
      before_action :set_layout, only: [:show, :update, :destroy, :status_metrics]
      
      # GET /api/v1/lot_map_layouts
      def index
        @layouts = @company.lot_map_layouts.includes(:lots).recent
        
        render json: {
          layouts: @layouts.map do |layout|
            layout.as_json(
              include: {
                lots: {
                  methods: [],
                  except: [:created_at, :updated_at]
                }
              },
              methods: [:coordinates]
            )
          end
        }
      end
      
      # GET /api/v1/lot_map_layouts/:id
      def show
        render json: {
          layout: @layout.as_json(
            include: {
              lots: {
                methods: [],
                except: [:created_at, :updated_at]
              }
            },
            methods: [:coordinates]
          )
        }
      end
      
      # POST /api/v1/lot_map_layouts
      def create
        @layout = @company.lot_map_layouts.new(layout_params)
        @layout.created_by = current_user&.email || 'system'
        
        if @layout.save
          render json: {
            layout: @layout.as_json(
              include: { lots: {} },
              methods: [:coordinates]
            )
          }, status: :created
        else
          render json: { errors: @layout.errors.full_messages }, status: :unprocessable_entity
        end
      end
      
      # PATCH/PUT /api/v1/lot_map_layouts/:id
      def update
        if @layout.update(layout_params)
          render json: {
            layout: @layout.as_json(
              include: { lots: {} },
              methods: [:coordinates]
            )
          }
        else
          render json: { errors: @layout.errors.full_messages }, status: :unprocessable_entity
        end
      end
      
      # DELETE /api/v1/lot_map_layouts/:id
      def destroy
        @layout.destroy
        head :no_content
      end
      
      # GET /api/v1/lot_map_layouts/:id/status_metrics
      def status_metrics
        render json: {
          metrics: @layout.status_metrics
        }
      end
      
      private
      
      def set_company
        @company = current_user&.company || Company.first
      end
      
      def set_layout
        @layout = @company.lot_map_layouts.find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Layout not found' }, status: :not_found
      end
      
      def layout_params
        params.require(:layout).permit(
          :name,
          :address,
          :latitude,
          :longitude,
          :boundary,
          :lot_count,
          :industry_type,
          :detected_from_satellite
        )
      end
    end
  end
end
