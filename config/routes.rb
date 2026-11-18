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

  # Receipts: the list, one receipt with its review form, the upload, and OCR requests. Photos are served by
  # the app behind sign-in (Receipts::PhotosController), never by Rails' own Active Storage routes, which are
  # not drawn. PATCH saves the review form (and accepts it, with intent=accept).
  resources :receipts, only: %i[ index show new create update ] do
    post :read, on: :member
    post :enter_by_hand, on: :member
    post :read_all, on: :collection
    get "photos/:id/:size", to: "receipts/photos#show", as: :photo, constraints: { id: /\d+/, size: /thumb|page|full/ }, format: false
  end

  # One transaction (read-only), and an expense entered by hand. There is no transactions list yet.
  resources :transactions, only: %i[ show new create ]

  # The REST API for AI agents and scripts: personal API tokens only (Api::BaseController).
  # JSON only: `format: false` drops the `.:format` suffix, so `/api/v1/transactions.xml` is not routed.
  namespace :api, defaults: { format: :json }, format: false do
    namespace :v1 do
      resource :status, only: :show, controller: :status
      resources :transactions, only: %i[ index show ]
      resources :accounts, only: :index
      resources :categories, only: :index
      resource :summary, only: :show
      resources :receipts, only: %i[ index show ]
    end
  end

  # The MCP server for AI assistants (McpController): personal API tokens only, POST only, stateless.
  # Every method is routed so the controller can answer the others with 405 after its checks.
  match "mcp", to: "mcp#handle", via: :all, format: false, as: :mcp

  # Sidekiq's dashboard, for a signed-in browser only (the same session cookie as every page). For anyone
  # else the route does not match, so they get a plain 404 and cannot tell that it exists.
  constraints ->(request) { Session.from_cookies(request.cookie_jar).present? } do
    mount Sidekiq::Web => "/sidekiq"
  end

  root "home#show"
end
