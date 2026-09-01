# frozen_string_literal: true

require 'rails_helper'

# The gate that actually locks a suspended company out.
#
# Suspending a company used to set a flag and enforce nothing. Refusing only at
# login would not have been enough either: anyone already signed in keeps a
# valid JWT, so they carry on working until it expires. Measured in production,
# three people kept working 90 seconds after their company was suspended.
# set_company_scope runs on every authenticated request that touches company
# data, which is why the check belongs here.
RSpec.describe ApplicationController, type: :controller do
  # Mirrors the shape of the 42 controllers that define their OWN
  # set_company_scope and override the base one. A gate living inside that
  # method would not run here at all , which is exactly how a suspended company
  # kept reading leads and tasks in production half an hour after it was locked
  # out of everything else.
  controller(ApplicationController) do
    before_action :set_company_scope

    def index
      render json: { ok: true }
    end

    private

    def set_company_scope
      @company = ::Company.find_by(id: current_company_id)
      Rails.logger.info "✅ [AnonymousController] Company scope set"
      true
    end
  end

  before { routes.draw { get 'index' => 'anonymous#index' } }

  let(:company) { create(:company, status: company_status) }
  let(:user) { User.new(id: 1, email: 'staff@example.com', company_id: company.id) }
  let(:company_status) { 'active' }

  def sign_in_as(acting_user, real_user: nil)
    allow(controller).to receive(:current_user).and_return(acting_user)
    allow(controller).to receive(:current_company_id).and_return(company.id)
    allow(controller).to receive(:original_user).and_return(real_user || acting_user)
    allow(controller).to receive(:set_current_attributes).and_return(true)
    # The gate keys off what authenticate leaves behind, so it has to be set the
    # way authenticate would rather than stubbed away wholesale.
    allow(controller).to receive(:authenticate) do
      controller.instance_variable_set(:@current_user_id, acting_user.id)
      true
    end
  end

  # Public and portal controllers skip :authenticate. The gate runs on them too
  # and must do nothing, or a billing flag would take a dealer's website down.
  def arrive_unauthenticated
    allow(controller).to receive(:current_company_id).and_return(company.id)
    allow(controller).to receive(:current_user).and_return(nil)
    allow(controller).to receive(:original_user).and_return(nil)
    allow(controller).to receive(:set_current_attributes).and_return(true)
    allow(controller).to receive(:authenticate).and_return(true)
  end

  context 'when the company is active' do
    it 'lets staff through' do
      sign_in_as(user)
      get :index
      expect(response).to have_http_status(:ok)
    end
  end

  %w[suspended cancelled].each do |status|
    context "when the company is #{status}" do
      let(:company_status) { status }

      it 'refuses staff on every request, not just at login' do
        sign_in_as(user)
        get :index

        expect(response).to have_http_status(:forbidden)
        expect(JSON.parse(response.body)['code']).to eq('company_suspended')
      end

      # The whole point of moving the gate out of set_company_scope.
      it 'refuses even a controller that overrides set_company_scope' do
        sign_in_as(user)
        get :index

        expect(response).to have_http_status(:forbidden)
        expect(response.body).not_to include('"ok"')
      end

      it 'leaves an unauthenticated public request alone' do
        arrive_unauthenticated
        get :index

        expect(response).to have_http_status(:ok)
      end

      # Otherwise nobody can reinstate the account they just switched off.
      it 'still lets a platform admin in' do
        admin = User.new(id: 2, email: 'admin@example.com', role: 'platform_admin')
        allow(admin).to receive(:platform_admin?).and_return(true)
        sign_in_as(admin)

        get :index
        expect(response).to have_http_status(:ok)
      end

      # current_user IS the impersonated employee during impersonation, so
      # reading it here would lock the admin out of the account they are
      # supporting.
      it 'still lets a platform admin in while impersonating an employee' do
        admin = User.new(id: 2, email: 'admin@example.com', role: 'platform_admin')
        allow(admin).to receive(:platform_admin?).and_return(true)
        sign_in_as(user, real_user: admin)

        get :index
        expect(response).to have_http_status(:ok)
      end
    end
  end
end
