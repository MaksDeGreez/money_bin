require "sidekiq/web"

Rails.application.routes.draw do
  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Sign in and sign out. There is no sign-up and no password reset page: the one user is created and
  # given a new password on the command line (lib/tasks/user.rake).
  resource :session, only: %i[ new create destroy ]

  # Personal API tokens for AI agents and scripts. "Destroy" revokes a token; the row is kept.
  namespace :settings do
    resources :api_tokens, only: %i[ index create destroy ]
  end

  # The REST API for AI agents and scripts: personal API tokens only (Api::BaseController).
  namespace :api, defaults: { format: :json } do
    namespace :v1 do
      resource :status, only: :show, controller: :status
      resources :transactions, only: %i[ index show ]
      resources :accounts, only: :index
      resources :categories, only: :index
      resource :summary, only: :show
      resources :receipts, only: %i[ index show ]
    end
  end

  # Sidekiq's dashboard, for a signed-in browser only (the same session cookie as every page). For anyone
  # else the route does not match, so they get a plain 404 and cannot tell that it exists.
  constraints ->(request) { Session.from_cookies(request.cookie_jar).present? } do
    mount Sidekiq::Web => "/sidekiq"
  end

  root "home#show"
end
