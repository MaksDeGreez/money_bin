require "sidekiq/web"

Rails.application.routes.draw do
  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Sign in and sign out. There is no sign-up and no password reset page: the one user is created and
  # given a new password on the command line (lib/tasks/user.rake).
  resource :session, only: %i[ new create destroy ]

  # Sidekiq's dashboard, for a signed-in browser only (the same session cookie as every page). For anyone
  # else the route does not match, so they get a plain 404 and cannot tell that it exists.
  constraints ->(request) { Session.from_cookies(request.cookie_jar).present? } do
    mount Sidekiq::Web => "/sidekiq"
  end

  root "home#show"
end
