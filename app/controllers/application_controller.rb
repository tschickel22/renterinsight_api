class ApplicationController < ActionController::API
  before_action :authenticate

  private

  def authenticate
    @current_company_id = (request.headers['X-Company-Id'] || 1).to_i
  end

  def current_company_id
    @current_company_id
  end
end
