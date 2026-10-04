# frozen_string_literal: true

# The TrueBuild factory readiness board (backlog E64): every factory's price
# book, drawings and checks, and releasing a factory so it can be given to
# dealers. Platform data, platform admins only, so no company scope.
class Api::Admin::TruebuildFactoriesController < ApplicationController
  before_action :require_platform_admin!
  before_action :set_factory, only: %i[release unrelease]

  # GET /api/admin/truebuild_factories?refresh=1
  def index
    render json: Truebuild::FactoryReadiness.board(refresh: params[:refresh].present?)
  end

  # POST /api/admin/truebuild_factories/:id/release { note }
  # Below the drawn bar it takes a reason: some factories pull models that
  # will never draw well and are still worth selling.
  def release
    row = Truebuild::FactoryReadiness.row(@factory.id)
    note = params[:note].to_s.strip
    below = row[:share] < Truebuild::FactoryReadiness.ready_share
    if below && note.blank?
      return render json: { error: "Only #{(row[:share] * 100).round}% of its photographed models are drawn. Say why it is ready anyway." },
                    status: :unprocessable_entity
    end

    @factory.update!(truebuild_released_at: Time.current, truebuild_released_by_id: current_user&.id, truebuild_release_note: note.presence)
    Truebuild::FactoryReadiness.bust!
    render json: Truebuild::FactoryReadiness.row(@factory.id)
  end

  # DELETE /api/admin/truebuild_factories/:id/release
  # Every dealer given it stops showing its homes at once; they keep it on
  # their list, so releasing it again brings it back for them.
  def unrelease
    @factory.update!(truebuild_released_at: nil, truebuild_released_by_id: nil, truebuild_release_note: nil)
    Truebuild::FactoryReadiness.bust!
    render json: Truebuild::FactoryReadiness.row(@factory.id)
  end

  # PUT /api/admin/truebuild_factories/ready_share { share } (0.5 to 1)
  def update_ready_share
    share = params[:share].to_f
    return render json: { error: 'Use a share between 50% and 100%' }, status: :unprocessable_entity unless share.between?(0.5, 1)

    Setting.set('platform', nil, Truebuild::FactoryReadiness::SETTING, share.to_s)
    Truebuild::FactoryReadiness.bust!
    render json: Truebuild::FactoryReadiness.board
  end

  private

  def set_factory
    @factory = Factory.find_by(id: params[:id])
    render json: { error: 'Not found' }, status: :not_found unless @factory
  end
end
