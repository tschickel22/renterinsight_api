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
  controller(ApplicationController) do
    before_action :set_company_scope

    def index
      render json: { ok: true }
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
    allow(controller).to receive(:authenticate).and_return(true)
    allow(controller).to receive(:set_current_attributes).and_return(true)
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
