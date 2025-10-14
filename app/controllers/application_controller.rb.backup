# frozen_string_literal: true
require "ostruct"

class ApplicationController < ActionController::API
  before_action :authenticate

  private

  def authenticate
    @current_company_id = (request.headers['X-Company-Id'] || 1).to_i
  end

  def current_company_id
    @current_company_id
  end

  def current_user
    # Temporary implementation until you add user authentication
    # Returns a simple object with id and company association
    @current_user ||= OpenStruct.new(id: 1, company_id: current_company_id)
  end
end
