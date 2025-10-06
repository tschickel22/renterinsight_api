# frozen_string_literal: true

Rails.application.config.middleware.insert_before 0, Rack::Cors do
  allow do
    # Allow common local dev origins (Vite/Netlify/React dev servers)
    origins %r{\Ahttp://localhost:\d+\z}, %r{\Ahttp://127\.0\.0\.1:\d+\z}

    resource '/api/*',
             headers: :any,
             methods: %i[get post patch put delete options head],
             credentials: true,
             expose: ['Content-Type']
  end
end
