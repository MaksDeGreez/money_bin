module Settings
  # The owner's personal API tokens: list, create, revoke.
  #
  # The plain token is shown exactly once, in the response to the create request itself. It is not put in
  # the session, the flash or a URL, so there is no second way to reach it: reloading that page would post
  # the form again and either fail (the name is taken) or make a different token. Every response here is
  # `Cache-Control: no-store`, and the created page also tells Turbo not to keep a snapshot of it.
  #
  # "Destroy" revokes: the row stays, so the list keeps the token's history.
  class ApiTokensController < ApplicationController
    before_action :no_store

    def index
      @api_token = ApiToken.new(scope: :read)
      @api_tokens = api_tokens.newest_first
    end

    def create
      attributes = params.expect(api_token: %i[ name scope ])
      @api_token, @plain_token = ApiToken.issue(user: Current.user, name: attributes[:name], scope: attributes[:scope])

      if @plain_token
        render :created, status: :created
      else
        @api_tokens = api_tokens.newest_first
        render :index, status: :unprocessable_content
      end
    end

    def destroy
      api_token = api_tokens.find(params[:id])
      api_token.revoke!
      redirect_to settings_api_tokens_path, status: :see_other,
        notice: "Revoked “#{api_token.name}”. Anything still using it now gets 401 Unauthorized."
    end

    private
      def api_tokens
        Current.user.api_tokens
      end
  end
end
